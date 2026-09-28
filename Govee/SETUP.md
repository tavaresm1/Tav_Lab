# Setup

Order matters. Step 2 before step 4, or the two integrations collide on the
`govee` domain.

---

## 1. Identify what is already installed

**Settings → Devices & Services.** Read the card name:

| Card name | What it is | Action |
|---|---|---|
| **Govee lights local** | Built-in `govee_light_local`. No credentials, discovered over UDP multicast. | Keep, optionally. See [step 5](#5-optional-keep-the-local-integration-as-a-latency-layer). |
| **Govee** (installed via HACS) | `LaggAt/hacs-govee` — **dead**. | Remove. See [step 2](#2-remove-the-dead-hacs-integration). |
| Both | Common. | Do both. |

To confirm the HACS one is LaggAt's, check
`config/custom_components/govee/manifest.json` for version `2025.1.1` and
requirement `govee-api-laggat==0.2.2`.

> It is **not** GitHub-archived, so HACS shows no warning. Its README carries a
> section titled *"Discontinuation - who wants to continue?"*.

---

## 2. Remove the dead HACS integration

Both the config entry **and** the repository — any successor also claims domain
`govee` and will collide.

1. Settings → Devices & Services → **Govee** → ⋮ → **Delete**.
2. HACS → Integrations → **Govee** (LaggAt) → ⋮ → **Remove**.
3. Restart Home Assistant.
4. Confirm `config/custom_components/govee/` is gone. If HACS left it behind,
   delete the directory manually and restart again.

Note the entity IDs you had in use before deleting — automations referencing them
will break, and the replacement may name things differently.

---

## 3. Get a Platform API key

Govee Home app → **Profile** → **About Us** → **Apply for API Key**. Arrives by
email.

As of 2026 the setup flow also involves **2FA**;
`lasswellt/govee-homeassistant` handles that in its config and reconfigure flows.

**Before installing anything**, verify your devices actually expose what you need:

```bash
GOVEE_API_KEY=your_key_here ./check-capabilities.sh
```

Look for `segmentedColorRgb`, `lightScene`, `diyScene` and `musicMode` on the
outdoor and TV-backlight SKUs. If the outdoor lights come back bare, use
`wez/govee2mqtt` instead — see [step 6](#6-fallback-govee2mqtt).

---

## 4. Install `lasswellt/govee-homeassistant`

1. HACS → ⋮ → **Custom repositories**.
2. Repository: `https://github.com/lasswellt/govee-homeassistant`, category
   **Integration**. Add.
3. Find **Govee**, **Download**, restart Home Assistant.
4. Settings → Devices & Services → **Add Integration** → **Govee**. Paste the API
   key, complete 2FA.
5. In the options flow, pick a **segment mode**:

| Mode | Behaviour |
|---|---|
| `DISABLED` | No segment entities. Least clutter. |
| `GROUPED` | One grouped segment entity per device. |
| `INDIVIDUAL` | One entity per segment. Most control, most entities. |
| `BOTH` | Grouped *and* individual. |

Start with `GROUPED` unless you know you want per-segment automations — 30
segments × several outdoor runs gets noisy fast.

### Verify

- Outdoor lights, TV kits and strips all appear as devices.
- TV kits have a **DreamView** switch and a **Music Mode** switch.
- Scene and DIY **select** entities are populated (not empty dropdowns).
- `govee.set_segment_color` appears in Developer Tools → Actions.

Empty scene selects usually mean the device did not return `dynamic_scene`; try
the `govee.refresh_scenes` action, then re-check with `check-capabilities.sh`.

---

## 5. Optional: keep the local integration as a latency layer

Only worth it for models whose **LAN Control** toggle actually exists in the
Govee Home app (per device, under the device's settings). It buys lower latency
and survives an internet outage. It buys **no** segments, no DIY, no real scenes.

> ### ⚠️ Do not run two LAN listeners
>
> Govee devices reply to **UDP port 4002**, and only one process on the host can
> bind it. Running `govee_light_local` alongside another LAN-capable tool —
> including this integration's own LAN mode, or govee2mqtt's LAN path — is a
> **port conflict**, not merely duplicate entities.
>
> Either leave the cloud integration's LAN mode off and let `govee_light_local`
> own 4002, or disable `govee_light_local` and let the cloud integration handle
> LAN. Not both.

Where both produce an entity for the same physical light, disable the redundant
**entity** (not the device) on one side, and point every automation at a single
`entity_id`. Two enabled entities for one light will fight over state.

---

## 6. Fallback: govee2mqtt

Only if the capability check rules out the HACS option for the outdoor lights.

Requires, honestly: a Docker container (or HA add-on), an MQTT broker
(Mosquitto add-on), and HA's MQTT integration — three moving parts and a second
discovery namespace.

- Segments arrive as discrete `Segment 00X` light entities.
- Scenes, DIY and music appear as **effect options** on the parent light, not as
  standalone entities.
- **No BLE support at all**, by design. WiFi-only.
- It performs a fresh Govee account login each refresh cycle; hammering that
  endpoint can trigger a **24-hour Govee-side login lockout**. Do not tighten the
  poll interval without reading its docs.

---

## If you own Bluetooth-only Govee devices

No cloud or LAN integration can reach them — all the WiFi transports structurally
exclude a device with no WiFi radio. Known BLE-only examples: **H6102**, **H6127**
strip, **H7002** outdoor string lights.

Those need HA's built-in **Govee BLE** integration or an **ESPHome Bluetooth
proxy** alongside the primary integration. Neither route was verified in this
research round.

One partial exception: BLE sensors that report through a Govee WiFi gateway are
readable over the cloud path.
