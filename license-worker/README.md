# Сервер лицензий Aurora (Cloudflare Worker)

Бесплатного тарифа Cloudflare хватает с запасом. Ключи подписи уже созданы на ПК: `%APPDATA%\aurora\` (`server.key`, `admin.key`, `admin.token`). Эти файлы никому не отправляйте и не кладите в репозиторий.

## Развернуть (один раз, на ПК)

Нужен Node.js. В папке `license-worker`:

1. Войдите в Cloudflare:
   ```
   npx wrangler login
   ```
2. Создайте хранилище и впишите напечатанный `id` в `wrangler.toml` вместо `REPLACE_WITH_KV_NAMESPACE_ID`:
   ```
   npx wrangler kv namespace create LICENSES
   ```
3. Секрет подписи (утилита печатает его, wrangler сразу сохраняет):
   ```
   go run ../tools/aurora-license secret | npx wrangler secret put SERVER_PRIVATE_KEY
   ```
4. Секрет администратора — содержимое `%APPDATA%\aurora\admin.token`:
   ```
   npx wrangler secret put ADMIN_TOKEN
   ```
5. Опубликуйте:
   ```
   npx wrangler deploy
   ```
   Wrangler напечатает адрес вида `https://aurora-license.<имя>.workers.dev`. Его нужно вписать в приложение: `Aurora/Shared/License.swift`, константа `LicenseClient.serverURL`.

## Выдавать ключи

- **С iPhone:** Aurora → Настройки → Лицензия → «Администратор». Один раз вставьте адрес сервера, `admin.token` и `admin.key`: они хранятся в связке ключей телефона. После этого: выпуск ключей, список, сброс привязки, отзыв, офлайн-ключ под устройство.
- **С ПК:** `go run ./tools/aurora-license issue -n 10 -days 365` (переменные `AURORA_LICENSE_URL` и `AURORA_ADMIN_TOKEN`).

## Как это работает

- Ключ `AUR-XXXXX-XXXXX-XXXXX-XXXXX` при первом вводе привязывается к устройству. На другом устройстве сервер ответит «Ключ уже активирован на другом устройстве».
- Устройство — это пара {UUID в связке ключей, identifierForVendor}; достаточно совпадения одного, поэтому переустановка не отнимает лицензию.
- Телефон получает подписанную аренду на 30 дней и проверяет её без сети; после окончания ещё 14 дней льготы. Продление идёт само, в том числе через включённый VPN.
- «Сброс» освобождает ключ для нового устройства, «Отзыв» выключает его (вступает в силу, когда закончится текущая аренда).
- При белых списках сервер на workers.dev может быть недоступен напрямую: активируйте по Wi‑Fi или через VPN. Если сервер недоступен совсем — выдайте офлайн-ключ под устройство.
