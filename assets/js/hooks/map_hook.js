import maplibregl from "maplibre-gl"
import { layers, namedFlavor } from "@protomaps/basemaps"
import { Protocol } from "pmtiles"

const protocol = new Protocol()

if (!window.__platserPmtilesProtocolRegistered) {
  maplibregl.addProtocol("pmtiles", protocol.tile)
  window.__platserPmtilesProtocolRegistered = true
}

// Returns distance in metres between two WGS-84 coordinates (Haversine formula).
function haversineMeters(lat1, lng1, lat2, lng2) {
  const R = 6371000
  const dLat = ((lat2 - lat1) * Math.PI) / 180
  const dLng = ((lng2 - lng1) * Math.PI) / 180
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos((lat1 * Math.PI) / 180) * Math.cos((lat2 * Math.PI) / 180) * Math.sin(dLng / 2) ** 2
  return R * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a))
}

// Deterministic colour for a member marker based on their user ID string.
function memberColor(userId) {
  const palette = [
    "#F97316", "#EAB308", "#84CC16", "#10B981",
    "#06B6D4", "#6366F1", "#A855F7", "#EC4899",
  ]
  let hash = 0
  for (let i = 0; i < userId.length; i++) hash = (hash * 31 + userId.charCodeAt(i)) >>> 0
  return palette[hash % palette.length]
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

function extendBounds(bounds, coordinates) {
  if (!Array.isArray(coordinates)) return bounds

  if (coordinates.length === 2 && coordinates.every(value => typeof value === "number")) {
    bounds.extend(coordinates)
    return bounds
  }

  coordinates.forEach(child => extendBounds(bounds, child))
  return bounds
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
    this.pickMode = false
    this.drawMode = false
    this.drawVertices = []

    // Live location sharing state
    this.memberMarkers = {}
    this.watchId = null
    this.lastLat = null
    this.lastLng = null
    this.lastPushTime = 0

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

    this._onSetBoundsClick = e => {
      if (e.target.closest("[data-set-map-area]") && this.map) {
        const b = this.map.getBounds()
        this.pushEvent("save_map_bounds", {
          west: b.getWest(),
          south: b.getSouth(),
          east: b.getEast(),
          north: b.getNorth(),
        })
      }
    }
    document.addEventListener("click", this._onSetBoundsClick)

    this.map.on("load", () => {
      this.mapReady = true
      this.pendingCallbacks.forEach(fn => fn())
      this.pendingCallbacks = []
    })

    this.map.on("click", e => {
      if (this.pickMode) {
        const {lat, lng} = e.lngLat
        this.pushEvent("poi_location_picked", {lat, lng})
        this._disablePickMode()
      } else if (this.drawMode) {
        const {lat, lng} = e.lngLat
        this.drawVertices.push([lng, lat])
        this._updateDrawPreview()
        this.pushEvent("vertex_added", {vertices: this.drawVertices})
      } else {
        const features = this.map.queryRenderedFeatures(e.point, {
          layers: ["poi-circles", "geofence-fills", "geofence-lines"],
        })

        const feature = features[0]
        if (feature?.id) {
          this.pushEvent("inspect_map_object", {
            kind: feature.layer?.id === "poi-circles" ? "poi" : "geofence",
            id: feature.id,
          })
        }
      }
    })

    this.handleEvent("map_init", ({pois, geofences, bounds}) => {
      this.runWhenReady(() => {
        this._initSources(pois, geofences)
        if (bounds) {
          this.map.fitBounds(
            [[bounds.west, bounds.south], [bounds.east, bounds.north]],
            {padding: 40, duration: 0}
          )
        }
      })
    })

    this.handleEvent("enable_location_pick", () => {
      this._enablePickMode()
    })

    this.handleEvent("disable_location_pick", () => {
      this._disablePickMode()
    })

    this.handleEvent("enable_draw_mode", () => {
      this.runWhenReady(() => this._enableDrawMode())
    })

    this.handleEvent("disable_draw_mode", () => {
      this.runWhenReady(() => this._disableDrawMode())
    })

    this.handleEvent("focus_map_object", payload => {
      this.runWhenReady(() => this._focusMapObject(payload))
    })

    this.handleEvent("fit_bounds", bounds => {
      this.runWhenReady(() => {
        if (bounds) {
          this.map.fitBounds(
            [[bounds.west, bounds.south], [bounds.east, bounds.north]],
            {padding: 40, duration: 450}
          )
        }
      })
    })

    this.handleEvent("undo_last_vertex", () => {
      this.runWhenReady(() => {
        if (this.drawVertices.length > 0) {
          this.drawVertices.pop()
          this._updateDrawPreview()
          this.pushEvent("vertex_added", {vertices: this.drawVertices})
        }
      })
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

    // Live location sharing events
    this.handleEvent("start_sharing", () => {
      this._startGeolocation()
    })

    this.handleEvent("stop_sharing", () => {
      this._stopGeolocation()
    })

    this.handleEvent("member_locations_init", ({locations}) => {
      this.runWhenReady(() => {
        locations.forEach(loc => this._upsertMemberMarker(loc.user_id, loc.lat, loc.lng, loc.display_name, loc.is_simulated))
      })
    })

    this.handleEvent("member_location_updated", ({user_id, lat, lng, display_name, is_simulated}) => {
      this.runWhenReady(() => this._upsertMemberMarker(user_id, lat, lng, display_name, is_simulated))
    })

    this.handleEvent("member_location_removed", ({user_id}) => {
      this.runWhenReady(() => this._removeMemberMarker(user_id))
    })
  },

  reconnected() {
    // If geolocation was active, push current location again to re-establish Presence
    if (this.watchId !== null && this.lastLat !== null) {
      this.pushEvent("location_update", {
        lat: this.lastLat,
        lng: this.lastLng,
        accuracy: null,
        heading: null,
      })
    }
  },

  runWhenReady(fn) {
    if (this.mapReady) {
      fn()
    } else {
      this.pendingCallbacks.push(fn)
    }
  },

  _enablePickMode() {
    this.pickMode = true
    this.el.style.cursor = "crosshair"
    if (this.map) this.map.getCanvas().style.cursor = "crosshair"
  },

  _disablePickMode() {
    this.pickMode = false
    this.el.style.cursor = ""
    if (this.map) this.map.getCanvas().style.cursor = ""
  },

  _enableDrawMode() {
    this.drawMode = true
    this.drawVertices = []
    this.el.style.cursor = "crosshair"
    this.map.getCanvas().style.cursor = "crosshair"
    this._setupDrawPreviewLayers()
  },

  _disableDrawMode() {
    this.drawMode = false
    this.drawVertices = []
    this.el.style.cursor = ""
    this.map.getCanvas().style.cursor = ""
    this._clearDrawPreview()
  },

  _focusMapObject(payload) {
    const geometry = payload?.geometry
    if (!geometry || !this.map) return

    if (geometry.type === "Point") {
      const [lng, lat] = geometry.coordinates
      this.map.flyTo({center: [lng, lat], zoom: Math.max(this.map.getZoom(), 15), duration: 450})
      return
    }

    if (geometry.type === "Polygon") {
      const bounds = new maplibregl.LngLatBounds()
      extendBounds(bounds, geometry.coordinates)
      this.map.fitBounds(bounds, {padding: 64, maxZoom: 16, duration: 450})
    }
  },

  _setupDrawPreviewLayers() {
    if (!this.map.getSource("draw-preview")) {
      this.map.addSource("draw-preview", {
        type: "geojson",
        data: {type: "FeatureCollection", features: []},
      })

      this.map.addLayer({
        id: "draw-fill",
        type: "fill",
        source: "draw-preview",
        filter: ["==", "$type", "Polygon"],
        paint: {"fill-color": "#6366F1", "fill-opacity": 0.15},
      })

      this.map.addLayer({
        id: "draw-outline",
        type: "line",
        source: "draw-preview",
        paint: {
          "line-color": "#6366F1",
          "line-width": 2,
          "line-dasharray": [3, 2],
        },
      })

      this.map.addLayer({
        id: "draw-vertices",
        type: "circle",
        source: "draw-preview",
        filter: ["==", "$type", "Point"],
        paint: {
          "circle-radius": 6,
          "circle-color": "#6366F1",
          "circle-stroke-width": 2,
          "circle-stroke-color": "#ffffff",
        },
      })
    }
  },

  _updateDrawPreview() {
    const verts = this.drawVertices
    const features = []

    verts.forEach(([lng, lat]) => {
      features.push({
        type: "Feature",
        geometry: {type: "Point", coordinates: [lng, lat]},
        properties: {},
      })
    })

    if (verts.length >= 3) {
      features.push({
        type: "Feature",
        geometry: {type: "Polygon", coordinates: [[...verts, verts[0]]]},
        properties: {},
      })
    } else if (verts.length >= 2) {
      features.push({
        type: "Feature",
        geometry: {type: "LineString", coordinates: verts},
        properties: {},
      })
    }

    const source = this.map.getSource("draw-preview")
    if (source) source.setData({type: "FeatureCollection", features})
  },

  _clearDrawPreview() {
    const source = this.map.getSource("draw-preview")
    if (source) source.setData({type: "FeatureCollection", features: []})
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

  // ---------------------------------------------------------------------------
  // Live location sharing
  // ---------------------------------------------------------------------------

  _startGeolocation() {
    if (!navigator.geolocation) return
    if (this.watchId !== null) return

    this.watchId = navigator.geolocation.watchPosition(
      pos => {
        const {latitude: lat, longitude: lng, accuracy, heading} = pos.coords
        const now = Date.now()
        const distMoved = this.lastLat !== null ? haversineMeters(this.lastLat, this.lastLng, lat, lng) : Infinity
        const timeSincePush = now - this.lastPushTime

        if (distMoved > 10 || timeSincePush > 10000) {
          this.lastLat = lat
          this.lastLng = lng
          this.lastPushTime = now
          this.pushEvent("location_update", {lat, lng, accuracy, heading})
        }
      },
      _err => {},
      {enableHighAccuracy: true, maximumAge: 5000, timeout: 10000},
    )
  },

  _stopGeolocation() {
    if (this.watchId !== null) {
      navigator.geolocation.clearWatch(this.watchId)
      this.watchId = null
    }
  },

  _upsertMemberMarker(userId, lat, lng, displayName, isSimulated = false) {
    if (this.memberMarkers[userId]) {
      this.memberMarkers[userId].setLngLat([lng, lat])
    } else {
      const el = document.createElement("div")
      el.className = "member-marker"
      el.style.cssText = [
        "width:36px",
        "height:36px",
        "border-radius:50%",
        "background:" + memberColor(userId),
        isSimulated ? "border:3px dashed rgba(255,255,255,0.95)" : "border:3px solid white",
        "box-shadow:0 2px 8px rgba(0,0,0,0.3)",
        "display:flex",
        "align-items:center",
        "justify-content:center",
        "font-size:13px",
        "font-weight:700",
        "color:white",
        "cursor:default",
        "user-select:none",
      ].join(";")

      el.textContent = (displayName || "?").charAt(0).toUpperCase()
      el.title = `${displayName || userId}${isSimulated ? " (simulated)" : ""}`

      const marker = new maplibregl.Marker({element: el})
        .setLngLat([lng, lat])
        .addTo(this.map)

      this.memberMarkers[userId] = marker
    }
  },

  _removeMemberMarker(userId) {
    if (this.memberMarkers[userId]) {
      this.memberMarkers[userId].remove()
      delete this.memberMarkers[userId]
    }
  },

  _clearAllMemberMarkers() {
    Object.keys(this.memberMarkers).forEach(userId => {
      this.memberMarkers[userId].remove()
    })
    this.memberMarkers = {}
  },

  destroyed() {
    this._stopGeolocation()
    this._clearAllMemberMarkers()
    if (this._onSetBoundsClick) {
      document.removeEventListener("click", this._onSetBoundsClick)
    }
    this.map?.remove()
  },
}
