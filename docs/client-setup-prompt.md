# Промпт для настройки клиентского устройства

Перед отправкой замените `<YOUR_KEY>` на содержимое `~/.local/share/ocx-lan-filter/key` с основного Mac
(`cat ~/.local/share/ocx-lan-filter/key`). Ключ в этот файл не записывайте.
Отправляйте промпт только в доверенный агент.

````
Задача: подключить к моему локальному окружению ОДНУ модель с другого ноутбука в домашней сети. Делай строго по шагам, ничего лишнего не трогай. Не удаляй и не переписывай существующие провайдеры и модели, только добавляй.

ДАННЫЕ ПОДКЛЮЧЕНИЯ
- Base URL: http://<MAC_LAN_IP>:10200/v1
- API-ключ: <YOUR_KEY>
- Протокол: OpenAI-совместимый, Chat Completions (POST /v1/chat/completions), поддерживается streaming.
- Единственная доступная модель: id "local-llm" (отображаемое имя "Local LLM"). Любой другой id сервер отклонит с 403. Какая именно модель стоит за этим алиасом, определяет хозяин сети и может меняться. Для тебя всегда просто "local-llm".
- Заголовок авторизации: Authorization: Bearer <ключ> (также принимается x-api-key).
- Контекст 1000000 токенов (1M), максимум ответа ~64000. Текст и картинки (image_url, jpeg/png/gif/webp) поддерживаются. Tool calling поддерживается.

ШАГ 1. Проверь доступность, пока ничего не настраивая
Выполни по очереди и покажи мне результат:
  curl -s -m 10 -o /dev/null -w "%{http_code}\n" http://<MAC_LAN_IP>:10200/v1/models
  (ожидается 401 без ключа. Если "connection refused" или таймаут, остановись и скажи мне: нужна проверка, что оба ноутбука в одной Wi-Fi сети и основной Mac не спит.)
  curl -s http://<MAC_LAN_IP>:10200/v1/models -H "Authorization: Bearer <YOUR_KEY>"
  (ожидается список из одной модели local-llm)
  curl -s -m 120 http://<MAC_LAN_IP>:10200/v1/chat/completions -H "Authorization: Bearer <YOUR_KEY>" -H "Content-Type: application/json" -d '{"model":"local-llm","messages":[{"role":"user","content":"What is 2+2? Just the number."}],"max_tokens":50}'
  (ожидается ответ с "4")

ШАГ 2. Определи, какой клиент стоит на этой машине, и добавь провайдера
Проверь какие из них установлены (`which opencode codex claude omp`) и настрой ТОЛЬКО те, что найдены.

A) opencode. Файл ~/.config/opencode/opencode.json. Если его нет, создай. Если есть, добавь ключ в существующий объект "provider", не затирая остальное:
  "local-lan": {
    "npm": "@ai-sdk/openai-compatible",
    "name": "Local LLM (LAN)",
    "options": {
      "baseURL": "http://<MAC_LAN_IP>:10200/v1",
      "apiKey": "<YOUR_KEY>"
    },
    "models": {
      "local-llm": {
        "name": "Local LLM",
        "attachment": true,
        "modalities": { "input": ["text", "image"], "output": ["text"] },
        "limit": { "context": 1000000, "output": 64000 }
      }
    }
  }
  Проверка: `opencode run --model local-lan/local-llm "What is 3+3? Just the number."`

B) Codex. Добавь в ~/.codex/config.toml, не меняя существующие строки:
  [model_providers.local_lan]
  name = "Local LLM (LAN)"
  base_url = "http://<MAC_LAN_IP>:10200/v1"
  env_key = "LOCAL_LAN_API_KEY"
  wire_api = "chat"
  И в профиль шелла (~/.zshrc) добавь: export LOCAL_LAN_API_KEY="<YOUR_KEY>"
  Проверка: `codex exec --skip-git-repo-check -c model_provider=local_lan --model local-llm "What is 1+1? Just the number."`
  Примечание: если установленная версия Codex не поддерживает wire_api="chat", не настраивай его молча. Сообщи мне версию и ошибку.

C) Claude Code. Он говорит на Anthropic API, а этот сервер отдаёт OpenAI Chat Completions, поэтому напрямую не подключится. Ничего не настраивай, просто сообщи мне об этом.

D) Любой другой клиент: используй общий формат (base URL, ключ, модель local-llm, тип "OpenAI-compatible").

ШАГ 3. Финальная проверка
Для каждого настроенного клиента покажи реальный ответ модели на тестовый запрос. Также убедись, что запрос к любой другой модели отклоняется:
  curl -s http://<MAC_LAN_IP>:10200/v1/chat/completions -H "Authorization: Bearer <YOUR_KEY>" -H "Content-Type: application/json" -d '{"model":"gpt-4o","messages":[{"role":"user","content":"hi"}]}'
  (ожидается HTTP 403 "only model 'local-llm' is available")

ПРАВИЛА
- Не коммить ключ в git и не клади его в репозитории. Только в пользовательские конфиги и ~/.zshrc.
- Не придумывай другие id моделей, доступен только "local-llm".
- Если что-то не совпадает с ожиданием, остановись и покажи мне точный вывод команды, не чини наугад.
- В конце дай короткий отчёт: какие файлы изменены, какие клиенты настроены, результаты проверок.
````
