# Gotchas

Known failure modes, verified 2026-09-28. Read before filing a bug upstream —
several of these are Govee-side and not the integration's fault.

---

## "Supported" means implemented, not working

Every project here lists SKUs it has *code paths* for. That is not the same as a
device that works. Open issues as of September 2026:

### `lasswellt/govee-homeassistant`

| Issue | Symptom |
|---|---|
| #213 | H66A0 TV Backlight 3 Pro — DreamView returns HTTP 200 but sync never starts (hence the `PTREAL_DREAMVIEW_SKUS` workaround in `const.py:420`) |
| #215 | Music Mode not working |
| #220 | H605B DreamView T1 Pro — power-off not working |
| #208 | H7026 — segment indices 16-29 affect the whole string |

### `wez/govee2mqtt`

| Issue | Symptom |
|---|---|
| #96 | H7021 reports only 15 of 30 segments — labelled `responsible:govee`, i.e. the API under-reports |
| #705 | Color writes silently fail while the device is in music mode |
| #99 | H6127 strip — BLE-only, open since Jan 2024, labelled `ble-only` + `needs:funding` |
| #560 | "BLE Proxy Support Proposal" (Dec 2025) — open, zero maintainer replies. Four BLE PRs exist, none merged. |

---

## Optimistic state

In `lasswellt/govee-homeassistant`, segment and scene state is **optimistic by
design** — the code comments say so outright (`select.py:912` *"Return current
selected scene from state (optimistic)"*, `switch.py:609` *"Uses optimistic state
since API may not return music mode status"*).

Consequence: **HA may show a scene or music mode that never actually applied.**
Do not build a conditional automation that trusts those states as ground truth.
This is why #213 is hard to notice — HTTP 200, entity flips, nothing happens.

---

## UDP port 4002 — only one listener

Govee devices reply to **UDP 4002**, and only one process on the host can bind
it. This bites when stacking integrations:

- `govee_light_local` (core) binds 4002.
- `lasswellt/govee-homeassistant` in LAN mode wants 4002.
- `govee2mqtt`'s LAN path wants 4002.

Running two is a **port conflict**, not merely duplicate entities. Pick one owner.

The full LAN path also needs UDP **4001** and **4003** reachable *on the devices*
— so a VLAN or firewall between HA and the lights breaks LAN control even when
nothing else is wrong.

---

## `govee_light_local` has no configuration UI

No manual IP entry, no interface selection. Discovery is UDP multicast only, so
failures across VLANs, subnets, container networks, or with multicast filtered
are **unfixable from inside HA**. Users were still hitting this on HA 2026.2.3
and 2026.3.4.

If HA runs in a container, it likely needs host networking for this to work at
all.

---

## Rate limiting

HTTP 429 on the cloud API is returned **with a retry-after delay** and the
command **fails outright rather than queueing** — a color command from an
automation simply doesn't happen. Observed in the wild as
`async_turn_on failed with 'API-Error 429 on command ... Rate limit exceeded'`
with a 39-second retry.

The control limit is the tight one: **2 req/sec/device** (burst 6). A dashboard
color picker dragged across a gradient will exceed that. So will a scene that
writes 30 segments in a loop with no delay.

No `X-RateLimit-*` headers are documented, so nothing can report remaining quota
— integrations budget blind.

---

## govee2mqtt: Govee account lockout

It performs a **fresh account login on every refresh cycle** against an
*undocumented* Govee auth endpoint (email + password, separate from the API key).
Hammering it triggers a Govee-side lockout that **blocks new logins for 24
hours**.

This is a distinct risk from the documented API's request caps, and tightening
the poll interval is how people hit it.

---

## Matter is not the escape hatch

Collected forum reports (not independently verified — see README open question 3):

- Matter-paired Govee lights expose only on/off, dimming and limited color. No
  micro-zones, no effects, no background-light control.
- HA scenes apply unreliably to Matter-native Govee downlights — brightness
  changes but color does not, while the Matter integration **logs success**.
- H6008 Matter-over-WiFi bulbs commission fine, then go unavailable within hours;
  factory reset and re-pair reproduces it.

So buying Matter Govee hardware does not remove the need for a cloud integration
for advanced features.

---

## Unlisted models degrade silently

`govee-local-api` knows 272 models (271 in the version HA core ships). A model
**not** in that table is still discovered on the LAN, but falls back to
`ON_OFF_CAPABILITIES` — a pure on/off entity, no color, no brightness, no
scenes. The log line is `Device %s is not supported. Only power control is
available`.

The top failure mode in its 2026 issues: H60B2, H60B0, H61D4, H61F6 (Strip Light
2 Pro) all reported as "only ON/OFF available, no effects/scenes".

Also: appearing in the supported list is **not sufficient** — the per-device LAN
Control toggle must exist in the app. See issues #172 (H7021) and #179 (H6008),
both listed-but-undiscovered.
