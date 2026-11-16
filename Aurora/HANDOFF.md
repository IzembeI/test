# Aurora — передача контекста для новой сессии

Начните новую сессию Claude Code в корне репозитория словами:
«Прочитай Aurora/HANDOFF.md и Aurora/README.md и продолжай работу над Aurora».

## Что это
Aurora — VPN-клиент для iOS (аналог Happ и INCY) на Xray-core. Язык интерфейса и общения — русский.
Ветка: `claude/lucid-maxwell-3ixd7b` репозитория `IzembeI/test`. Папка `Aurora/`. Старое приложение Mercury (клавиатура) в корне — не трогать.

## Устройство
- `Aurora/Core/` — Go-мост (gomobile → `Corebridge.xcframework`): Xray-core 26.11.9 (через libXray для разбора ссылок).
  - `bridge.go` — Start(config, tunFd, assetDir) / Stop / Stats (трафик, лучший член балансировщика из observatory) / SetMemoryLimit (GOGC 50, FreeOSMemory раз в 20 с).
  - `config.go` — BuildConfig(options JSON) → полный конфиг Xray: режимы rule/global/direct, обход РФ без geo-баз, реклама, QUIC, свои списки, FakeDNS, фрагментация, mux, цепочка, балансировщик leastPing+observatory (`outbounds` + `configs` — полные JSON-конфиги вливаются со своими dialerProxy-цепочками через extractChain), APNs через прокси раньше остальных правил, connIdle, bufferKB, AsIs если нет IP-правил, адреса серверов резолвятся прямым DNS.
  - `links.go` — ParseLinks/DecodeSubscription: vless, vmess (base64 и URL), trojan, ss, socks, hysteria2 (+salamander, pinSHA256; insecure в Xray 26 удалён), wireguard.
  - `ping.go` — URLTestDetailed (полные конфиги тестируются целиком, ошибки текстом), TCPPing.
  - `analyze.go` — Analyze: оценка конфига 0..100 для сотовой/белых списков, Wi‑Fi и DPI + пояснения (Reality, SNI под российские домены, порт, страна, UDP, фрагментация).
  - Тесты: `cd Aurora/Core && go test ./...` (Go 1.27, работает без Mac).
- `Aurora/Shared/` — общий Swift для приложения и расширения: модели (AppSettings, TunnelPayload, TunnelStats, Provision/SigningAdvice), Storage (App Group если есть, иначе свой контейнер; loadMerged), Notifier (все виды уведомлений, тихие часы), GeoDownloader.
- `Aurora/Tunnel/PacketTunnelProvider.swift` — NEPacketTunnelProvider: fd utun ищется перебором, Xray TUN через `xray.tun.fd`; DNS 198.19.0.2 (перехват 53 → dns-out); IPv6 всегда в туннель; переподключение при смене сети/сне; при автопилоте сам меняет набор серверов Wi‑Fi ↔ сотовая (optionsWifi/optionsCellular); уведомления о смене сервера, квоте, обрыве; IPC: stats/logs/reload/updateGeo/notifyTest.
- `Aurora/App/` — SwiftUI: Home (кнопка, автопилот, скорость, подписка), Servers, Routing (профили в формате Happ), Settings (уведомления, подключение, белые списки, обход блокировок, пинг/подписки, оформление, статистика, журнал, конфиг, «Подпись и VPN»), Autopilot.swift, Intents (Siri), QR.
- Сборка: `.github/workflows/aurora.yml` (macos-15): gomobile → кэш фреймворка → XcodeGen → xcodebuild без подписи → ad-hoc codesign с entitlements → `Aurora.ipa` (артефакт `Aurora-ipa`). Очередь macOS-раннеров иногда зависает — помогает новый push.

## Что известно от пользователя (важно)
- Живёт в Александрове; мобильный интернет с «белыми списками» и глушилками.
- Подписывает IPA в ESign/Feather-подобном приложении enterprise-сертификатом «iPhone Distribution»; включено «Удалить mobileprovision» (профиль в бандле недоступен), «Удаление URL схемы» выключено. VPN с этим сертификатом **работает** (проверено на устройстве).
- По его опыту push при белых списках приходят, если APNs не исключён из VPN, подключён сервер РФ и включено «DNS из JSON» — так и сделано по умолчанию + пресет «Режим белых списков».
- Провайдер помечает серверы: `[SIM|Глушилки]`, `[Глушилки]`, `[WI-FI]`, РФ («СИБИРЬ»), «Автовыбор»; серверы — полные JSON-конфиги (gRPC/TLS, Reality).
- Хочет: автопилот по всем подпискам, максимально быстрый; «изучает» сами конфиги и выбирает/меняет сервер сам.

## Проверено на устройстве
Установка, подключение, работа VPN, подписка с заголовками (трафик/срок).

## Исправлено после первого запуска, на устройстве ещё не проверено
- Кракозябры в объявлении (заголовки HTTP Latin-1 → UTF-8).
- Пинг «нет» у JSON-серверов (теперь тест целого конфига + причина ошибки).
- Нули статистики (опрос стартует при запуске и подключении).
- Низкая скорость: MTU 9000, буфер 64 КБ, мягкий GC, AsIs.
- Автопилот целиком (анализ конфигов, два прохода проверки, наборы для Wi‑Fi/сотовой, переключение в расширении).

## Идеи на будущее
- Виджет/Control Center (iOS 18 ControlWidget) и Live Activity со статусом.
- Учёт оператора (MTS/Билайн/МегаФон/Tele2) в истории здоровья.
- Самодиагностика скорости (speedtest через туннель) и подбор MTU/фрагментации.
