# Govee ↔ Home Assistant

Which integration to use for **Govee** devices in Home Assistant, and why. The
deciding criterion here is **device coverage** — one integration that exposes
every Govee product in the house, including segment/zone control, scenes, DIY
modes and music/video modes.

All findings verified **2026-09-28** against primary sources (project source
code and Govee's own developer docs). Repo metrics drift; see
[Time sensitivity](#time-sensitivity).

> **Status: decision made, not yet implemented.** Nothing in this directory has
> been applied to a live Home Assistant instance. Run
> [`check-capabilities.sh`](check-capabilities.sh) first — it resolves the one
> open question that could change the recommendation.

---

## Decision

**Install [`lasswellt/govee-homeassistant`](https://github.com/lasswellt/govee-homeassistant) via HACS.**

It is the only option that stacks all four transports (cloud Platform API +
MQTT push + LAN + some BLE) *inside* Home Assistant with no external broker, and
the only one with first-class TV-backlight/DreamView entities. That matches the
constraint of keeping things in HA.

**Fallback:** [`wez/govee2mqtt`](https://github.com/wez/govee2mqtt) if the
capability check shows the outdoor lights are unsupported, or if the HACS option
proves unstable. More mature, but costs a container + an MQTT broker + HA's MQTT
integration.

### Why not the obvious choices

| Option | Verdict |
|---|---|
| Core **Govee Lights Local** (`govee_light_local`) | Keep as an optional local-latency layer. **Cannot** meet the requirement — one light entity per device, zero segment code, 11 hardcoded scenes. |
| HACS **Govee** (`LaggAt/hacs-govee`) | **Dead.** Remove it. Maintainer-declared discontinued, pinned to a 2022 library, on/off + brightness + color temp + color only. |
| **Matter/Thread** | Does not appear to bypass any of this. Unresolved — see [Open questions](#open-questions). |

---

## Candidate comparison

| | `lasswellt/govee-homeassistant` | `wez/govee2mqtt` |
|---|---|---|
| Install | HACS custom repo | Docker/add-on + MQTT broker + MQTT integration |
| Extra infrastructure | none | three moving parts, second discovery namespace |
| Age / traction | created 2026-01-14, ~129★, 1052 commits | ~2.5 yrs, ~1.5k★ |
| Release cadence | ~weekly (10 releases in Sept 2026 alone) | tag `2026.03.25-ab9deb66` |
| TV backlight / DreamView | ✅ dedicated DreamView switch, music-mode switch, scene + DIY selects | ✅ scenes/DIY/music as light effects |
| Segments | ✅ 4 segment modes + `govee.set_segment_color` action | ✅ discrete `Segment 00X` light entities |
| Outdoor H705x | ⚠️ **unclaimed** — no outdoor row in its device table | ⚠️ probably better, never directly compared |
| BLE-only devices | ✅ native BLE discovery — confirmed in `manifest.json` | ❌ none, by design |
| Non-light platforms | leak sensors, purifiers, fans | appliances, sensors |
| Risk | young, largely AI-generated, 4 watchers, no third-party audit | per-SKU bugs, Govee-side auth lockout risk |

Features in the HACS option were confirmed **in code**, not just in its README:
`switch.py:141` creates `GoveeDreamViewSwitchEntity` when
`device.supports_dreamview`; `switch.py:594` a music-mode switch; `select.py:141`
DIY-scene selects; `const.py:436-444` the four segment modes;
`services.yaml` defines `set_segment_color`, `refresh_scenes`, `send_raw_ptreal`.

Its **BLE support is real**, not incidental — verified in `manifest.json`
(fetched 2026-09-30), which is a meaningful advantage over govee2mqtt:

```json
"after_dependencies": ["bluetooth"],
"dependencies": ["bluetooth_adapters", "network"],
"bluetooth": [
  {"local_name": "Govee_*"}, {"local_name": "ihoment_*"},
  {"local_name": "GBK_*"}, {"manufacturer_id": 34819}
]
```

Same file declares `iot_class: cloud_push` (so MQTT push, not bare polling) and
`quality_scale: platinum` — the latter self-declared, not HA-audited, since this
is not a core integration.

---

## Transport reality

Only the cloud Platform API exposes the capability taxonomy the advanced
features need:

| Capability | What it buys | LAN | Cloud |
|---|---|---|---|
| `segment_color_setting` | per-segment color/brightness | ✗ (not in HA) | ✅ |
| `dynamic_scene` (`lightScene`, `diyScene`, `snapshot`) | the app's real scene library | ✗ | ✅ |
| `music_setting` (`musicMode`) | music mode | ✗ | ✅ |

The LAN *protocol* does carry scenes — but core's `govee_light_local` surfaces
only **11 hardcoded generic** ones (sunrise, sunset, movie, dating, romantic,
twinkle, candlelight, snowflake, energetic, breathe, crossing), handed to every
scene-capable model. There is no segment handling in `light.py` at all, and LAN
control is lights-only and must be toggled on **per device** in the Govee Home
app. Models absent from the library's 272-model table still get discovered but
degrade to a pure on/off entity.

### Rate limits — the "10,000/day" figure is wrong for the current API

The modern endpoint `openapi.api.govee.com/router/api/v1/...` has **no daily
cap**. It is per-minute/second:

| Endpoint | Limit |
|---|---|
| `/user/devices` | 30 req/min/account |
| `/device/state` | 30 req/min/device |
| `/device/scenes` | 30 req/min/device |
| `/device/control` | 12 req/sec/account (burst 80) **and 2 req/sec/device** (burst 6) |

So ~2 s is the fastest sustainable per-device poll, and dragging a color slider
will return HTTP 429. No `X-RateLimit-*` headers are documented, so integrations
budget blind.

The 10,000/day number belongs to the **legacy** `developer-api.govee.com`.

> **Nomenclature trap:** say "openapi.api.govee.com Platform API" rather than
> "v2". The confusingly-named older "Govee HTTP API v2" is a different thing, and
> the no-daily-quota statement is false for it.

---

## Files here

| File | What it is |
|---|---|
| [`SETUP.md`](SETUP.md) | Identify what's installed, migrate, install, verify |
| [`check-capabilities.sh`](check-capabilities.sh) | Queries your real devices for `segmentedColorRgb` / `lightScene` / `diyScene` / `musicMode` |
| [`GOTCHAS.md`](GOTCHAS.md) | Known bugs, the UDP 4002 conflict, what "supported" does not mean |
| [`sources.md`](sources.md) | Cited primary sources |
| `research/findings.json` | Raw verified findings, with per-claim evidence and adversarial vote counts |
| `research/deep-research-workflow.js` | The workflow script that produced the above, for reproducibility |

---

## Open questions

1. **Do the actual outdoor and TV SKUs return the advanced capabilities?** Three
   separate claims that Govee's cloud list covers the H605x TV and H705x outdoor
   families were refuted or split 1-2 by the verification pass — checks kept
   hitting HTTP 429 on Govee's model-list page. Treat "the cloud API covers my
   outdoor lights" as **probable but unverified**. `check-capabilities.sh`
   settles it in one call.
2. **Does `lasswellt/govee-homeassistant` control H705x outdoor permanent lights,
   segments included?** Its README device table has no outdoor row; H7075/H7076
   appear only in the credits. Unclaimed, so unverified.
3. **Does Matter/Thread provide a local path with segment and scene control?** No
   verified finding. Collected forum threads suggest Matter-paired Govee lights
   expose only on/off + dimming + basic color, with some going unavailable after
   hours — so probably not, but this could change the recommendation for newly
   purchased devices.
4. **Behaviour on a large install (20+ devices)** under the 30 req/min/device
   state cap — default poll intervals, 429 back-off, and whether govee2mqtt's
   undocumented IoT MQTT channel actually delivers push state for *lights*
   (relieving REST polling) or only for appliances/sensors. That MQTT-push claim
   was refuted 1-2 and is unresolved.

---

## Time sensitivity

- Repo metrics verified **2026-09-28** and will drift. `lasswellt/govee-homeassistant`
  ships roughly weekly (`v2026.9.15` was published the day of verification).
- Model counts move with nearly every PR: HA core ships `govee-local-api==3.1.0`
  with **271** models; the library's `develop` branch has **272**.
- `SUPPORTED_DEVICES.md` exists only on `develop` (404 on `main`).

## Research provenance and its limits

Produced by a fan-out research workflow: 5 search angles → 18 sources fetched →
90 claims extracted → top 25 put through 3-vote adversarial verification (2/3
refutes kills a claim) → **15 confirmed, 10 refuted**, synthesized to 9 findings.
100 agent calls.

Two gaps worth knowing about:

- **Community consensus is unevidenced.** Search engines returned bot challenges
  during verification, so no r/homeassistant, r/Govee or HA-forum corroboration
  survived. Everything above rests on source code and vendor docs — arguably
  better evidence, but it means there is no "what do real users report" signal.
- **`lasswellt/govee-homeassistant` coverage claims are maintainer self-reports**
  in its own README, with no third-party audit.

The 10 refuted claims are kept in `research/findings.json` under `refuted`,
with vote counts — worth reading before re-researching something.
