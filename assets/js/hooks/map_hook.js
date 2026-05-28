import maplibregl from "maplibre-gl"
import { layers, namedFlavor } from "@protomaps/basemaps"
import { Protocol } from "pmtiles"

const protocol = new Protocol()

if (!window.__platserPmtilesProtocolRegistered) {
  maplibregl.addProtocol("pmtiles", protocol.tile)
  window.__platserPmtilesProtocolRegistered = true
}

function buildStyle(mapUrl, flavorName, language) {
  if (!mapUrl.startsWith("pmtiles://") && !mapUrl.startsWith("https://") && !mapUrl.startsWith("http://")) {
    mapUrl = "pmtiles://" + mapUrl
  }

  if (mapUrl.startsWith("pmtiles://")) {
    const flavor = namedFlavor(flavorName)
    const style = {
      version: 8,
      sources: {
        protomaps: {
          type: "vector",
          url: mapUrl,
          attribution:
            '<a href="https://github.com/protomaps/basemaps">Protomaps</a> © <a href="https://osm.org/copyright">OpenStreetMap</a>',
        },
      },
      layers: layers("protomaps", flavor, {lang: language}),
      glyphs: "https://protomaps.github.io/basemaps-assets/fonts/{fontstack}/{range}.pbf",
    }

    if (flavorName === "light" || flavorName === "dark") {
      style.sprite = `https://protomaps.github.io/basemaps-assets/sprites/v4/${flavorName}`
    }

    return style
  }

  // Raster tile fallback (e.g. OpenStreetMap)
  return {
    version: 8,
    sources: {
      raster: {
        type: "raster",
        tiles: [mapUrl],
        tileSize: 256,
        attribution: '© <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a>',
      },
    },
    layers: [{id: "raster-tiles", type: "raster", source: "raster"}],
  }
}

function parseCenter(value) {
  if (!value) {
    return [0, 0]
  }

  const parts = value.split(",").map(part => Number.parseFloat(part.trim()))
  const [lat, lon] = parts

  if (Number.isNaN(lat) || Number.isNaN(lon)) {
    return [0, 0]
  }

  return [lon, lat]
}

function parseZoom(value) {
  if (!value) {
    return 2
  }

  const zoom = Number.parseFloat(value)

  return Number.isNaN(zoom) ? 2 : zoom
}

export default {
  mounted() {
    const pmtilesUrl = this.el.dataset.pmtilesUrl

    if (!pmtilesUrl) {
      throw new Error("Map hook requires data-pmtiles-url")
    }

    this.sourceData = {
      pois: {type: "FeatureCollection", features: []},
      geofences: {type: "FeatureCollection", features: []},
    }

    this.mapReady = false
    this.pendingCallbacks = []

    this.map = new maplibregl.Map({
      container: this.el,
      style: buildStyle(
        pmtilesUrl,
        this.el.dataset.mapFlavor ?? "light",
        this.el.dataset.mapLanguage ?? "en",
      ),
      center: parseCenter(this.el.dataset.mapCenter),
      zoom: parseZoom(this.el.dataset.mapZoom),
      attributionControl: true,
      cooperativeGestures: true,
    })

    this.map.addControl(new maplibregl.NavigationControl(), "top-right")

    this.map.on("load", () => {
      this.mapReady = true
      this.pendingCallbacks.forEach(fn => fn())
      this.pendingCallbacks = []
    })

    this.handleEvent("map_init", ({pois, geofences}) => {
      this.runWhenReady(() => this._initSources(pois, geofences))
    })

    this.handleEvent("poi_added", feature => {
      this.runWhenReady(() => this._upsertFeature("pois", feature))
    })

    this.handleEvent("poi_updated", feature => {
      this.runWhenReady(() => this._upsertFeature("pois", feature))
    })

    this.handleEvent("poi_removed", ({id}) => {
      this.runWhenReady(() => this._removeFeature("pois", id))
    })

    this.handleEvent("geofence_added", feature => {
      this.runWhenReady(() => this._upsertFeature("geofences", feature))
    })

    this.handleEvent("geofence_updated", feature => {
      this.runWhenReady(() => this._upsertFeature("geofences", feature))
    })

    this.handleEvent("geofence_removed", ({id}) => {
      this.runWhenReady(() => this._removeFeature("geofences", id))
    })
  },

  runWhenReady(fn) {
    if (this.mapReady) {
      fn()
    } else {
      this.pendingCallbacks.push(fn)
    }
  },

  _initSources(pois, geofences) {
    this.sourceData.pois = pois
    this.sourceData.geofences = geofences

    if (!this.map.getSource("pois")) {
      this.map.addSource("pois", {type: "geojson", data: pois})
    } else {
      this.map.getSource("pois").setData(pois)
    }

    if (!this.map.getSource("geofences")) {
      this.map.addSource("geofences", {type: "geojson", data: geofences})
    } else {
      this.map.getSource("geofences").setData(geofences)
    }

    if (!this.map.getLayer("geofence-fills")) {
      this.map.addLayer({
        id: "geofence-fills",
        type: "fill",
        source: "geofences",
        paint: {
          "fill-color": ["coalesce", ["get", "color"], "#6366F1"],
          "fill-opacity": 0.2,
        },
      })
    }

    if (!this.map.getLayer("geofence-lines")) {
      this.map.addLayer({
        id: "geofence-lines",
        type: "line",
        source: "geofences",
        paint: {
          "line-color": ["coalesce", ["get", "color"], "#6366F1"],
          "line-width": 2,
          "line-opacity": 0.8,
        },
      })
    }

    if (!this.map.getLayer("poi-circles")) {
      this.map.addLayer({
        id: "poi-circles",
        type: "circle",
        source: "pois",
        paint: {
          "circle-radius": 9,
          "circle-color": "#3B82F6",
          "circle-stroke-width": 2,
          "circle-stroke-color": "#ffffff",
        },
      })
    }
  },

  _upsertFeature(sourceId, feature) {
    const data = this.sourceData[sourceId]
    if (!data) return
    data.features = data.features.filter(f => f.id !== feature.id)
    data.features.push(feature)
    const source = this.map.getSource(sourceId)
    if (source) source.setData(data)
  },

  _removeFeature(sourceId, id) {
    const data = this.sourceData[sourceId]
    if (!data) return
    data.features = data.features.filter(f => f.id !== id)
    const source = this.map.getSource(sourceId)
    if (source) source.setData(data)
  },

  destroyed() {
    this.map?.remove()
  },
}
