import LanModelCore

enum S {
    static let appName = "LAN Model Proxy"

    static var statusOK: String { tr("Работает", "Running") }
    static var statusWarning: String { tr("Есть замечания", "Needs attention") }
    static var statusDown: String { tr("Не работает", "Not running") }
    static var statusPaused: String { tr("Все эндпоинты выключены", "All endpoints are off") }

    static var newEndpoint: String { tr("Новый эндпоинт…", "New endpoint…") }
    static var restartService: String { tr("Перезапустить сервис", "Restart service") }
    static var openLog: String { tr("Открыть лог", "Open log") }
    static var settings: String { tr("Настройки", "Settings") }
    static var launchAtLogin: String { tr("Запускать при входе", "Launch at login") }
    static var quit: String { tr("Выйти", "Quit") }
    static var probe: String { tr("Проверить", "Test") }
    static var edit: String { tr("Изменить…", "Edit…") }
    static var install: String { tr("Установить", "Install") }
    static var update: String { tr("Обновить", "Update") }
    static var start: String { tr("Запустить", "Start") }
    static var openFile: String { tr("Открыть файл", "Open file") }
    static var save: String { tr("Сохранить", "Save") }
    static var cancel: String { tr("Отменить", "Cancel") }
    static var delete: String { tr("Удалить", "Delete") }
    static var overwrite: String { tr("Перезаписать", "Overwrite") }
    static var back: String { tr("Назад", "Back") }

    static func warning(_ w: Warning) -> String {
        switch w {
        case .serviceNotInstalled: return tr("Сервис не установлен", "Service is not installed")
        case .serviceStopped: return tr("Сервис не запущен", "Service is not running")
        case .serviceOutdated(let v): return tr("Нужно обновить сервис (v\(v) → v2)", "Service needs an update (v\(v) → v2)")
        case .runtimeMissing: return tr("Сервис не сообщает статус. Подождите секунду или перезапустите его",
                                        "The service reports no status. Wait a second or restart it")
        case .ocxUnreachable: return tr("ocx недоступен на 127.0.0.1", "ocx is unreachable on 127.0.0.1")
        case .configInvalid(let m): return tr("Конфиг отклонён, работает прошлая версия: \(m)",
                                              "Config rejected, the previous version keeps running: \(m)")
        case .endpointError(let id, let m): return tr("Эндпоинт «\(id)»: \(m)", "Endpoint “\(id)”: \(m)")
        case .modelMissing(let ep, let alias, let model):
            return tr("«\(ep)»: модели \(model) нет в ocx (алиас \(alias))", "“\(ep)”: model \(model) is not in ocx (alias \(alias))")
        case .keyMissing(let ep): return tr("У эндпоинта «\(ep)» нет файла ключа", "Endpoint “\(ep)” has no key file")
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
        case .listening: return tr("слушает", "listening")
        case .error: return tr("ошибка", "error")
        case .disabled: return tr("выключен", "off")
        case nil: return tr("нет данных", "no data")
        }
    }

    static func validationHint(_ m: String) -> String {
        switch m {
        case "duplicate port": return tr("Этот порт уже занят другим эндпоинтом", "This port is used by another endpoint")
        case "duplicate alias": return tr("Такой алиас уже есть", "This alias already exists")
        case "duplicate id": return tr("Такой id уже есть", "This id already exists")
        case "must be 1024..65535": return tr("Порт должен быть от 1024 до 65535", "Port must be between 1024 and 65535")
        case "conflicts with the upstream port": return tr("Порт совпадает с портом ocx", "The port equals the ocx port")
        case "must be 1..64 characters": return tr("От 1 до 64 символов", "1 to 64 characters")
        case "must be 1..200 characters": return tr("Укажите модель (до 200 символов)", "Specify a model (up to 200 characters)")
        case "at least one alias required": return tr("Нужен хотя бы один алиас", "At least one alias is required")
        case "must be 1..10000000": return tr("От 1 до 10 000 000", "1 to 10,000,000")
        default:
            if m.hasPrefix("must match") {
                return tr("Допустимы буквы, цифры, . _ : - (первый символ буква или цифра)",
                          "Letters, digits and . _ : - are allowed (start with a letter or digit)")
            }
            if m.hasPrefix("must be a relative path") { return tr("Недопустимый путь к ключу", "Invalid key path") }
            return m
        }
    }
}
