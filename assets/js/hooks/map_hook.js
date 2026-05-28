import maplibregl from "maplibre-gl"
import { layers, namedFlavor } from "@protomaps/basemaps"
import { Protocol } from "pmtiles"

const protocol = new Protocol()

if (!window.__platserPmtilesProtocolRegistered) {
  maplibregl.addProtocol("pmtiles", protocol.tile)
  window.__platserPmtilesProtocolRegistered = true
}

function buildStyle(pmtilesUrl, flavorName, language) {
  const flavor = namedFlavor(flavorName)
  const style = {
    version: 8,
    sources: {
      protomaps: {
        type: "vector",
        url: pmtilesUrl,
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

function parseCenter(value) {
  if (!value) {
    return [0, 0]
  }

  const [longitude, latitude] = value
    .split(",")
    .map(part => Number.parseFloat(part.trim()))

  if (Number.isNaN(longitude) || Number.isNaN(latitude)) {
    return [0, 0]
  }

  return [longitude, latitude]
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
  },

  destroyed() {
    this.map?.remove()
  },
}
