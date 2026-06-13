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

function currentMapBounds(map) {
  const b = map.getBounds()

  return {
    west: b.getWest(),
    south: b.getSouth(),
    east: b.getEast(),
    north: b.getNorth(),
  }
}

function pointsEqual(a, b) {
  return a[0] === b[0] && a[1] === b[1]
}

function distance(a, b) {
  return Math.hypot(a[0] - b[0], a[1] - b[1])
}

function smoothRing(ring, cornerRatio = 0.05, segments = 2) {
  if (!Array.isArray(ring) || ring.length < 4) return ring

  const closed = pointsEqual(ring[0], ring[ring.length - 1])
  const points = closed ? ring.slice(0, -1) : ring.slice()
  const count = points.length

  if (count < 3) return ring

  const smoothed = []

  for (let i = 0; i < count; i++) {
    const prev = points[(i - 1 + count) % count]
    const curr = points[i]
    const next = points[(i + 1) % count]

    const prevLen = distance(prev, curr)
    const nextLen = distance(curr, next)

    if (prevLen === 0 || nextLen === 0) {
      smoothed.push(curr)
      continue
    }

    const cornerCut = Math.min(prevLen, nextLen) * cornerRatio
    const startT = cornerCut / prevLen
    const endT = cornerCut / nextLen

    const start = [
      curr[0] + (prev[0] - curr[0]) * startT,
      curr[1] + (prev[1] - curr[1]) * startT,
    ]
    const end = [
      curr[0] + (next[0] - curr[0]) * endT,
      curr[1] + (next[1] - curr[1]) * endT,
    ]

    smoothed.push(start)

    for (let step = 1; step < segments; step++) {
      const t = step / segments
      const inv = 1 - t
      smoothed.push([
        inv * inv * start[0] + 2 * inv * t * curr[0] + t * t * end[0],
        inv * inv * start[1] + 2 * inv * t * curr[1] + t * t * end[1],
      ])
    }

    smoothed.push(end)
  }

  if (smoothed.length > 0 && !pointsEqual(smoothed[0], smoothed[smoothed.length - 1])) {
    smoothed.push(smoothed[0])
  }

  return smoothed
}

function smoothGeometry(geometry) {
  if (!geometry || !geometry.type) return geometry

  if (geometry.type === "Polygon") {
    return {
      ...geometry,
      coordinates: geometry.coordinates.map((ring, index) =>
        // Keep holes intact to avoid accidental self-intersections.
        index === 0 ? smoothRing(ring) : ring,
      ),
    }
  }

  if (geometry.type === "MultiPolygon") {
    return {
      ...geometry,
      coordinates: geometry.coordinates.map(polygon =>
        polygon.map((ring, index) => (index === 0 ? smoothRing(ring) : ring)),
      ),
    }
  }

  return geometry
}

function smoothFeature(feature) {
  if (!feature?.geometry) return feature
  return {
    ...feature,
    geometry: smoothGeometry(feature.geometry),
  }
}

function smoothFeatureCollection(collection) {
  if (!collection?.features) return collection
  return {
    ...collection,
    features: collection.features.map(smoothFeature),
  }
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
    this.hoverPopup = null
    this.temporarySearchMarker = null
    this.temporarySearchPopup = null

    // Live location sharing state
    this.memberMarkers = {}
    this.checkInMarkers = {}
    this.watchId = null
    this.lastLat = null
    this.lastLng = null
    this.lastPushTime = 0
    this.checkInPending = false

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
        const b = currentMapBounds(this.map)
        this.pushEvent("save_map_bounds", {
          west: b.west,
          south: b.south,
          east: b.east,
          north: b.north,
        })
      }
    }
    document.addEventListener("click", this._onSetBoundsClick)

    this._onCheckInClick = e => {
      if (e.target.closest("[data-check-in]")) {
        this._requestCheckIn()
      }
    }
    document.addEventListener("click", this._onCheckInClick)

    this._onCreatePoiFromSearchResultClick = e => {
      const target =
        e.target.closest?.("[data-create-poi-from-search-result]") ||
        e.target.querySelector?.("[data-create-poi-from-search-result]")

      if (target) {
        e.preventDefault()
        e.stopPropagation()
        this.pushEvent("create_poi_from_search_result", {})
      }
    }
    document.addEventListener("click", this._onCreatePoiFromSearchResultClick)

    this._onClearTemporarySearchPinClick = e => {
      const target =
        e.target.closest?.("[data-clear-temporary-search-pin]") ||
        e.target.querySelector?.("[data-clear-temporary-search-pin]")

      if (target) {
        e.preventDefault()
        e.stopPropagation()
        this.pushEvent("clear_temporary_search_pin", {})
      }
    }
    document.addEventListener("click", this._onClearTemporarySearchPinClick)

    this._onSearchSubmit = e => {
      const form = e.target.closest?.("#map-search-form")
      if (form && this.map) {
        this._writeSearchViewportBounds(form)
      }
    }
    document.addEventListener("submit", this._onSearchSubmit, true)

    this.map.on("load", () => {
      this.mapReady = true
      this.pendingCallbacks.forEach(fn => fn())
      this.pendingCallbacks = []
      this._setupHoverAffordance()
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
          layers: [
            "poi-circles",
            "geofence-boundary-fills",
            "geofence-boundary-lines",
            "geofence-fills",
            "geofence-lines",
          ],
        })

        const feature = features[0]
        const featureId = feature?.properties?.id
        if (featureId) {
          this.pushEvent("inspect_map_object", {
            kind: feature.layer?.id === "poi-circles" ? "poi" : "geofence",
            id: featureId,
          })
        }
      }
    })

    this.handleEvent("map_init", ({pois, geofences, bounds, check_ins = []}) => {
      this.runWhenReady(() => {
        this._initSources(pois, geofences)
        check_ins.forEach(checkIn => {
          this._upsertCheckInMarker(checkIn.user_id, checkIn.lat, checkIn.lng)
        })
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

    this.handleEvent("show_temporary_search_pin", payload => {
      this.runWhenReady(() => this._showTemporarySearchPin(payload))
    })

    this.handleEvent("clear_temporary_search_pin", () => {
      this.runWhenReady(() => this._clearTemporarySearchPin())
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

    this.handleEvent("check_in_added", ({user_id, lat, lng}) => {
      this.runWhenReady(() => this._upsertCheckInMarker(user_id, lat, lng))
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

  _writeSearchViewportBounds(form) {
    const bounds = currentMapBounds(this.map)
    const fields = {
      viewport_west: bounds.west,
      viewport_south: bounds.south,
      viewport_east: bounds.east,
      viewport_north: bounds.north,
    }

    Object.entries(fields).forEach(([name, value]) => {
      const input = form.querySelector(`input[name="search[${name}]"]`)
      if (input) input.value = String(value)
    })
  },

  _enablePickMode() {
    this.pickMode = true
    this.hoverPopup?.remove()
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
    this.hoverPopup?.remove()
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

  _setupHoverAffordance() {
    const canvas = this.map.getCanvas()
    const interactiveLayers = [
      "poi-circles",
      "geofence-fills",
      "geofence-lines",
    ]

    this.hoverPopup = new maplibregl.Popup({
      closeButton: false,
      closeOnClick: false,
      offset: 14,
      className: "poi-hover-popup",
    })

    this.map.on("mousemove", e => {
      if (this.pickMode || this.drawMode) {
        this.hoverPopup.remove()
        return
      }

      const features = this.map.queryRenderedFeatures(e.point, {layers: interactiveLayers})

      if (features.length > 0) {
        canvas.style.cursor = "pointer"
        const name = features[0].properties?.name
        if (name) {
          this.hoverPopup.setLngLat(e.lngLat).setText(name).addTo(this.map)
        } else {
          this.hoverPopup.remove()
        }
      } else {
        canvas.style.cursor = ""
        this.hoverPopup.remove()
      }
    })

    this.map.on("mouseout", () => {
      if (!this.pickMode && !this.drawMode) canvas.style.cursor = ""
      this.hoverPopup.remove()
    })
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
        layout: {
          "line-join": "round",
          "line-cap": "round",
        },
        paint: {
          "line-color": "#6366F1",
          "line-width": 3,
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

  _showTemporarySearchPin(payload) {
    const lat = Number.parseFloat(payload?.lat)
    const lng = Number.parseFloat(payload?.lng)
    if (!Number.isFinite(lat) || !Number.isFinite(lng)) return

    this._clearTemporarySearchPin()

    const container = document.createElement("div")
    container.className = "temporary-search-pin"
    container.dataset.temporarySearchPin = "true"
    container.dataset.createPoiFromSearchResult = "true"
    container.style.cssText = [
      "display:flex",
      "flex-direction:column",
      "align-items:center",
      "gap:8px",
      "transform:translateY(-2px)",
      "position:relative",
      "z-index:5",
      "pointer-events:auto",
    ].join(";")

    const card = document.createElement("div")
    card.style.cssText = [
      "min-width:180px",
      "max-width:240px",
      "border:1px solid rgba(15,23,42,0.12)",
      "border-radius:12px",
      "background:rgba(255,255,255,0.96)",
      "box-shadow:0 12px 30px rgba(15,23,42,0.22)",
      "padding:10px",
      "font-family:system-ui,-apple-system,BlinkMacSystemFont,'Segoe UI',sans-serif",
      "backdrop-filter:blur(10px)",
    ].join(";")

    const header = document.createElement("div")
    header.style.cssText = [
      "display:flex",
      "align-items:flex-start",
      "gap:8px",
      "margin-bottom:3px",
    ].join(";")

    const meta = document.createElement("div")
    meta.textContent = [payload?.source_label, payload?.kind_label].filter(Boolean).join(" · ")
    meta.style.cssText = [
      "flex:1",
      "min-width:0",
      "font-size:11px",
      "font-weight:700",
      "color:#2563EB",
      "white-space:nowrap",
      "overflow:hidden",
      "text-overflow:ellipsis",
    ].join(";")

    const clear = document.createElement("button")
    clear.id = "temporary-search-pin-clear"
    clear.type = "button"
    clear.dataset.clearTemporarySearchPin = "true"
    clear.setAttribute("aria-label", "Clear temporary search pin")
    clear.title = "Clear temporary search pin"
    clear.textContent = "x"
    clear.style.cssText = [
      "width:22px",
      "height:22px",
      "border:0",
      "border-radius:999px",
      "background:#F3F4F6",
      "color:#4B5563",
      "font-size:16px",
      "font-weight:800",
      "line-height:20px",
      "cursor:pointer",
      "display:flex",
      "align-items:center",
      "justify-content:center",
      "padding:0",
      "flex-shrink:0",
    ].join(";")
    clear.addEventListener("mouseenter", () => {
      clear.style.background = "#E5E7EB"
      clear.style.color = "#111827"
    })
    clear.addEventListener("mouseleave", () => {
      clear.style.background = "#F3F4F6"
      clear.style.color = "#4B5563"
    })

    const title = document.createElement("div")
    title.textContent = payload?.title || "Selected place"
    title.style.cssText = [
      "font-size:13px",
      "font-weight:800",
      "color:#111827",
      "line-height:1.25",
      "overflow:hidden",
      "display:-webkit-box",
      "-webkit-line-clamp:2",
      "-webkit-box-orient:vertical",
    ].join(";")

    const action = document.createElement("button")
    action.id = "temporary-search-pin-create-poi"
    action.type = "button"
    action.dataset.createPoiFromSearchResult = "true"
    action.textContent = "Create POI"
    action.style.cssText = [
      "margin-top:8px",
      "width:100%",
      "border:0",
      "border-radius:9px",
      "background:#2563EB",
      "color:white",
      "font-size:12px",
      "font-weight:800",
      "padding:7px 9px",
      "cursor:pointer",
      "box-shadow:0 1px 2px rgba(15,23,42,0.16)",
    ].join(";")
    action.addEventListener("mouseenter", () => { action.style.background = "#1D4ED8" })
    action.addEventListener("mouseleave", () => { action.style.background = "#2563EB" })

    header.appendChild(meta)
    header.appendChild(clear)
    card.appendChild(header)
    card.appendChild(title)
    card.appendChild(action)

    const pin = document.createElement("div")
    pin.style.cssText = [
      "width:34px",
      "height:34px",
      "background:#2563EB",
      "border:3px solid white",
      "border-radius:50% 50% 50% 0",
      "box-shadow:0 4px 12px rgba(15,23,42,0.3)",
      "display:flex",
      "align-items:center",
      "justify-content:center",
      "transform:rotate(-45deg)",
      "transform-origin:center center",
      "color:white",
      "font-size:15px",
      "font-weight:900",
      "outline:2px dashed rgba(37,99,235,0.35)",
      "outline-offset:3px",
    ].join(";")

    const pinDot = document.createElement("span")
    pinDot.textContent = "+"
    pinDot.style.cssText = [
      "transform:rotate(45deg)",
      "line-height:1",
      "margin-top:-1px",
      "user-select:none",
    ].join(";")
    pin.appendChild(pinDot)

    container.appendChild(pin)

    this.temporarySearchMarker = new maplibregl.Marker({element: container, anchor: "bottom"})
      .setLngLat([lng, lat])
      .addTo(this.map)

    this.temporarySearchPopup = new maplibregl.Popup({
      closeButton: false,
      closeOnClick: false,
      offset: [0, -42],
      className: "temporary-search-popup",
    })
      .setDOMContent(card)
      .setLngLat([lng, lat])
      .addTo(this.map)

    if (payload?.bounds) {
      this.map.fitBounds(
        [[payload.bounds.west, payload.bounds.south], [payload.bounds.east, payload.bounds.north]],
        {padding: 72, maxZoom: 16, duration: 450}
      )
    } else {
      this.map.flyTo({center: [lng, lat], zoom: Math.max(this.map.getZoom(), 15), duration: 450})
    }
  },

  _clearTemporarySearchPin() {
    if (this.temporarySearchMarker) {
      this.temporarySearchMarker.remove()
      this.temporarySearchMarker = null
    }
    if (this.temporarySearchPopup) {
      this.temporarySearchPopup.remove()
      this.temporarySearchPopup = null
    }
  },

  _initSources(pois, geofences) {
    const renderedGeofences = smoothFeatureCollection(geofences)

    this.sourceData.pois = pois
    this.sourceData.geofences = renderedGeofences

    if (!this.map.getSource("pois")) {
      this.map.addSource("pois", {type: "geojson", data: pois})
    } else {
      this.map.getSource("pois").setData(pois)
    }

    if (!this.map.getSource("geofences")) {
      this.map.addSource("geofences", {type: "geojson", data: renderedGeofences})
    } else {
      this.map.getSource("geofences").setData(renderedGeofences)
    }

    if (!this.map.getLayer("geofence-fills")) {
      this.map.addLayer({
        id: "geofence-boundary-fills",
        type: "fill",
        source: "geofences",
        filter: ["==", ["get", "purpose"], "boundary"],
        paint: {
          "fill-color": ["coalesce", ["get", "color"], "#6366F1"],
          "fill-opacity": 0.08,
        },
      })

      this.map.addLayer({
        id: "geofence-boundary-lines",
        type: "line",
        source: "geofences",
        filter: ["==", ["get", "purpose"], "boundary"],
        layout: {
          "line-join": "round",
          "line-cap": "round",
        },
        paint: {
          "line-color": ["coalesce", ["get", "color"], "#6366F1"],
          "line-width": 4,
          "line-opacity": 0.9,
          "line-dasharray": [2, 2],
        },
      })

      this.map.addLayer({
        id: "geofence-fills",
        type: "fill",
        source: "geofences",
        filter: ["!=", ["get", "purpose"], "boundary"],
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
        filter: ["!=", ["get", "purpose"], "boundary"],
        layout: {
          "line-join": "round",
          "line-cap": "round",
        },
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
          "circle-color": ["coalesce", ["get", "color"], "#3B82F6"],
          "circle-stroke-width": 2,
          "circle-stroke-color": "#ffffff",
        },
      })
    }

  },

  _upsertFeature(sourceId, feature) {
    const data = this.sourceData[sourceId]
    if (!data) return
    const renderedFeature = sourceId === "geofences" ? smoothFeature(feature) : feature
    data.features = data.features.filter(f => f.id !== renderedFeature.id)
    data.features.push(renderedFeature)
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

  _geolocationUnavailableMessage(action) {
    if (!navigator.geolocation) {
      return `Your browser does not support location ${action}.`
    }

    if (!window.isSecureContext) {
      return `Location ${action} requires HTTPS or localhost.`
    }

    return null
  },

  _requestCheckIn() {
    const unavailableMessage = this._geolocationUnavailableMessage("check-ins")
    if (unavailableMessage) {
      this.pushEvent("check_in_error", {message: unavailableMessage})
      return
    }

    if (this.checkInPending) return

    this.checkInPending = true

    navigator.geolocation.getCurrentPosition(
      pos => {
        const {latitude: lat, longitude: lng} = pos.coords
        this.checkInPending = false
        this.pushEvent("check_in", {lat, lng})
      },
      error => {
        this.checkInPending = false

        const message =
          error.code === 1
            ? "Location permission denied. Check in could not be recorded."
            : error.code === 2
              ? "Your location could not be determined right now."
              : error.code === 3
                ? "Location lookup timed out."
                : error.message || "Could not record check-in."

        this.pushEvent("check_in_error", {message})
      },
      {enableHighAccuracy: true, maximumAge: 0, timeout: 10000},
    )
  },

  _upsertCheckInMarker(userId, lat, lng) {
    if (this.checkInMarkers[userId]) {
      this.checkInMarkers[userId].setLngLat([lng, lat])
      return
    }

    const el = document.createElement("div")
    el.className = "check-in-marker"
    el.style.cssText = [
      "width:28px",
      "height:28px",
      "background:#F59E0B",
      "border:3px solid white",
      "border-radius:50% 50% 50% 0",
      "box-shadow:0 2px 8px rgba(0,0,0,0.28)",
      "display:flex",
      "align-items:center",
      "justify-content:center",
      "transform:rotate(-45deg)",
      "transform-origin:center center",
      "color:white",
      "font-size:14px",
      "font-weight:800",
      "user-select:none",
      "cursor:default",
    ].join(";")

    const label = document.createElement("span")
    label.textContent = "⚑"
    label.style.transform = "rotate(45deg)"
    el.appendChild(label)

    const marker = new maplibregl.Marker({element: el})
      .setLngLat([lng, lat])
      .addTo(this.map)

    this.checkInMarkers[userId] = marker
  },

  _removeCheckInMarker(userId) {
    if (this.checkInMarkers[userId]) {
      this.checkInMarkers[userId].remove()
      delete this.checkInMarkers[userId]
    }
  },

  _clearAllCheckInMarkers() {
    Object.keys(this.checkInMarkers).forEach(userId => {
      this.checkInMarkers[userId].remove()
    })
    this.checkInMarkers = {}
  },

  // ---------------------------------------------------------------------------
  // Live location sharing
  // ---------------------------------------------------------------------------

  _startGeolocation() {
    const unavailableMessage = this._geolocationUnavailableMessage("sharing")
    if (unavailableMessage) {
      this.pushEvent("location_error", {message: unavailableMessage})
      return
    }
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
    this._clearTemporarySearchPin()
    this._clearAllMemberMarkers()
    this._clearAllCheckInMarkers()
    if (this._onSetBoundsClick) {
      document.removeEventListener("click", this._onSetBoundsClick)
    }
    if (this._onCheckInClick) {
      document.removeEventListener("click", this._onCheckInClick)
    }
    if (this._onCreatePoiFromSearchResultClick) {
      document.removeEventListener("click", this._onCreatePoiFromSearchResultClick)
    }
    if (this._onClearTemporarySearchPinClick) {
      document.removeEventListener("click", this._onClearTemporarySearchPinClick)
    }
    if (this._onSearchSubmit) {
      document.removeEventListener("submit", this._onSearchSubmit, true)
    }
    this.hoverPopup?.remove()
    this.map?.remove()
  },
}
