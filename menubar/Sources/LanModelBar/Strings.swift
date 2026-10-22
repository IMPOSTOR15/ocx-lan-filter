import LanModelCore

enum S {
    static let appName = "LAN Model Proxy"
    static let editorTitle = "Редактор эндпоинтов"

    static let statusOK = "Работает"
    static let statusWarning = "Есть замечания"
    static let statusDown = "Не работает"
    static let statusPaused = "Все эндпоинты выключены"

    static let newEndpoint = "Новый эндпоинт…"
    static let openEditor = "Редактор эндпоинтов…"
    static let restartService = "Перезапустить сервис"
    static let openLog = "Открыть лог"
    static let launchAtLogin = "Запускать при входе"
    static let quit = "Выйти"
    static let probe = "Проверить"
    static let copyKey = "Ключ"
    static let edit = "Изменить…"
    static let install = "Установить"
    static let update = "Обновить"
    static let start = "Запустить"
    static let openFile = "Открыть файл"
    static let save = "Сохранить"
    static let cancel = "Отменить"
    static let delete = "Удалить"
    static let reload = "Перезагрузить"
    static let overwrite = "Перезаписать"

    static func warning(_ w: Warning) -> String {
        switch w {
        case .serviceNotInstalled: return "Сервис не установлен"
        case .serviceStopped: return "Сервис не запущен"
        case .serviceOutdated(let v): return "Нужно обновить сервис (v\(v) → v2)"
        case .runtimeMissing: return "Сервис не сообщает статус. Подождите секунду или перезапустите его"
        case .ocxUnreachable: return "ocx недоступен на 127.0.0.1"
        case .configInvalid(let m): return "Конфиг отклонён, работает прошлая версия: \(m)"
        case .endpointError(let id, let m): return "Эндпоинт «\(id)»: \(m)"
        case .modelMissing(let ep, let alias, let model): return "«\(ep)»: модели \(model) нет в ocx (алиас \(alias))"
        case .keyMissing(let ep): return "У эндпоинта «\(ep)» нет файла ключа"
        }
    }

    static func overallLabel(_ s: OverallStatus) -> String {
        switch s {
        case .ok: return statusOK
        case .warning: return statusWarning
        case .down: return statusDown
        case .paused: return statusPaused
        }
    }

    static func stateLabel(_ s: EndpointState?) -> String {
        switch s {
        case .listening: return "слушает"
        case .error: return "ошибка"
        case .disabled: return "выключен"
        case nil: return "нет данных"
        }
    }

    static func validationHint(_ m: String) -> String {
        switch m {
        case "duplicate port": return "Этот порт уже занят другим эндпоинтом"
        case "duplicate alias": return "Такой алиас уже есть"
        case "duplicate id": return "Такой id уже есть"
        case "must be 1024..65535": return "Порт должен быть от 1024 до 65535"
        case "conflicts with the upstream port": return "Порт совпадает с портом ocx"
        case "must be 1..64 characters": return "От 1 до 64 символов"
        case "must be 1..200 characters": return "Укажите модель (до 200 символов)"
        case "at least one alias required": return "Нужен хотя бы один алиас"
        case "must be 1..10000000": return "От 1 до 10 000 000"
        default:
            if m.hasPrefix("must match") { return "Допустимы буквы, цифры, . _ : - (первый символ буква или цифра)" }
            if m.hasPrefix("must be a relative path") { return "Недопустимый путь к ключу" }
            return m
        }
    }
}
