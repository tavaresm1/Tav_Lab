# Sources

Fetched and extracted 2026-09-28. Full per-claim evidence, quotes and adversarial
vote counts are in `research/findings.json`.

## Primary — project source and vendor docs

Load-bearing for every confirmed finding.

| Source | Used for |
|---|---|
| [home-assistant.io/integrations/govee_light_local](https://www.home-assistant.io/integrations/govee_light_local/) | Core LAN integration: `local_push`, lights-only, per-device app toggle |
| [home-assistant/core — `govee_light_local`](https://github.com/home-assistant/core/tree/dev/homeassistant/components/govee_light_local) | `PLATFORMS = [Platform.LIGHT]`, no segment code, the 11 `SCENE_CODES` |
| [Galorhallen/govee-local-api — `SUPPORTED_DEVICES.md`](https://github.com/Galorhallen/govee-local-api/blob/develop/SUPPORTED_DEVICES.md) | 272-model table, H70xx segment columns (`develop` only — 404 on `main`) |
| [developer.govee.com — Get You Devices](https://developer.govee.com/reference/get-you-devices) | Capability taxonomy + the rate-limit table |
| [developer.govee.com — Get Devices Status](https://developer.govee.com/reference/get-devices-status) | 30 req/min/device state limit |
| [developer.govee.com — Control You Devices](https://developer.govee.com/reference/control-you-devices.md) | 12 req/sec/account, 2 req/sec/device (`updatedAt` 2025-11-12) |
| [developer.govee.com — Subscribe Device Event](https://developer.govee.com/reference/subscribe-device-event) | MQTT push scope (claim refuted 1-2, unresolved) |
| [developer.govee.com — supported product model](https://developer.govee.com/docs/support-product-model) | Attempted SKU verification — **returned HTTP 429**, see open question 1 |
| [Govee legacy API reference (PDF)](https://govee-public.s3.amazonaws.com/developer-docs/GoveeDeveloperAPIReference.pdf) | Where the 10,000/day cap actually comes from |
| [lasswellt/govee-homeassistant](https://github.com/lasswellt/govee-homeassistant) | Maintenance status, lineage, DreamView/music/segment code |
| [wez/govee2mqtt](https://github.com/wez/govee2mqtt) · [`SKUS.md`](https://github.com/wez/govee2mqtt/blob/main/docs/SKUS.md) · [`LAN.md`](https://github.com/wez/govee2mqtt/blob/main/docs/LAN.md) · [`platform_api.rs`](https://github.com/wez/govee2mqtt/blob/main/src/platform_api.rs) | Capability matrix, the verbatim no-BLE statement, transport split |
| [LaggAt/hacs-govee](https://github.com/LaggAt/hacs-govee) · [README](https://raw.githubusercontent.com/LaggAt/hacs-govee/master/README.md) | The "Discontinuation" section, `cloud_polling`, 158 open issues |
| [PyPI — `govee-api-laggat`](https://pypi.org/project/govee-api-laggat/) | `0.2.2`, last upload 2022-04-05, legacy endpoint hardcoded |
| [dekamaru/ha_govee_lan_control](https://github.com/dekamaru/ha_govee_lan_control) | UDP 4001/4002/4003 and the single-listener constraint |

## Forum — corroborating, weaker

Used for pain points and the Matter picture. No Matter finding survived
verification; treat these as directional.

| Thread | Topic |
|---|---|
| [429 rate limit exceeded](https://community.home-assistant.io/t/govee-integration-not-working-properly-error-429-rate-limit-exceeded/547411) | 429 fails commands outright, 39 s retry-after |
| [Better integration for Govee Matter lights](https://community.home-assistant.io/t/better-integration-for-govee-matter-lights-limited-functionality-in-home-assistant/950525) | Matter exposes only basic control |
| [Matter lights unreliable with HA scenes](https://community.home-assistant.io/t/govee-matter-lights-unreliable-with-ha-scenes/970593) | Scenes partially apply while logs report success |
| [Matter-over-WiFi unavailability](https://community.home-assistant.io/t/having-issues-with-govee-bulb-with-matter-over-wifi-unavailability-after-some-time/956730) | H6008 goes unavailable within hours |
| [Problems getting Govee Lights Local working](https://community.home-assistant.io/t/having-problems-getting-the-govee-lights-local-integration-working/775190) | No config UI; still failing on HA 2026.2.3 / 2026.3.4 |
| [Movie/Music DreamView workaround](https://community.home-assistant.io/t/work-around-for-movie-and-music-dreamview-using-the-govee-cloud-integration/1025519) | DreamView modes *are* controllable via the cloud integration |
| [govee2mqtt issue #702](https://github.com/wez/govee2mqtt/issues/702) | Fresh login per refresh → 24 h Govee lockout |
| [HA community search index](https://community.home-assistant.io/search.json?q=govee) | Thread survey |

## What is missing

**Reddit is absent.** r/homeassistant and r/Govee were in scope but search
engines returned bot challenges throughout verification, so nothing from there
survived. Community consensus is therefore the weakest part of this research;
everything load-bearing rests on source code and vendor docs instead.

Also unverified: HA's built-in **Govee BLE** integration, **govee-ble**,
**LED-BLE**, and the **ESPHome Bluetooth proxy** route — the options for
Bluetooth-only devices. None were examined.
