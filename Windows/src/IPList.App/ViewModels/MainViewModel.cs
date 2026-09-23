using System.Collections.ObjectModel;
using System.ComponentModel;
using System.Runtime.CompilerServices;
using System.Text.Json;
using System.Windows.Input;
using IPList.Core.Catalog;
using IPList.Core.Export;
using IPList.Core.Networking;
using IPList.Core.Refresh;
using IPList.Core.State;

namespace IPList.Windows.ViewModels;

public sealed class ServiceRow : INotifyPropertyChanged
{
    private bool _selected;
    public required string Id { get; init; }
    public required string Name { get; init; }
    public required string Category { get; init; }
    public required string Evidence { get; init; }
    public required string Details { get; init; }
    public int RouteCount { get; init; }
    public bool Selected { get => _selected; set { if (_selected == value) return; _selected = value; PropertyChanged?.Invoke(this, new(nameof(Selected))); } }
    public event PropertyChangedEventHandler? PropertyChanged;
}

public sealed class ManualRow
{
    public required string Value { get; init; }
    public string Group { get; init; } = "";
    public string Note { get; init; } = "";
}

public sealed class MainViewModel : INotifyPropertyChanged
{
    private readonly AppPersistenceCoordinator _persistence;
    private readonly RefreshPipeline _pipeline;
    private readonly string _statePath;
    private readonly string _exportPath;
    private readonly SemaphoreSlim _mutationGate = new(1, 1);
    private AppState _state = new();
    private string _search = "";
    private string _status = "Готово к проверке источников";
    private string _error = "";
    private string _routesText = "Нет маршрутов. Проверьте источники.";
    private bool _isBusy;
    private bool _isLoaded;

    public MainViewModel(AppPersistenceCoordinator persistence, RefreshPipeline pipeline, string dataDirectory)
    {
        _persistence = persistence;
        _pipeline = pipeline;
        _statePath = Path.Combine(dataDirectory, "state.json");
        _exportPath = Path.Combine(dataDirectory, "amnezia-direct.json");
        RefreshCommand = new AsyncCommand(RefreshAsync, () => !IsBusy && IsLoaded);
    }

    public event PropertyChangedEventHandler? PropertyChanged;
    public event EventHandler? DataChanged;
    public ObservableCollection<ServiceRow> Services { get; } = [];
    public ObservableCollection<ManualRow> ManualRoutes { get; } = [];
    public ObservableCollection<ChangeRecord> History { get; } = [];
    public ObservableCollection<string> Diagnostics { get; } = [];
    public ICommand RefreshCommand { get; }
    public AppState State => _state;
    public string DataDirectory => Path.GetDirectoryName(_statePath)!;
    public string ExportPath => _exportPath;
    public string Status { get => _status; private set => Set(ref _status, value); }
    public string Error { get => _error; private set => Set(ref _error, value); }
    public string RoutesText { get => _routesText; private set => Set(ref _routesText, value); }
    public bool IsBusy { get => _isBusy; private set { Set(ref _isBusy, value); (RefreshCommand as AsyncCommand)?.RaiseCanExecuteChanged(); } }
    public bool IsLoaded => _isLoaded;
    public string Search { get => _search; set { Set(ref _search, value); RebuildServices(); } }
    public ExportMode Mode => _state.Mode;
    public bool HasActiveCatalog => _state.Catalog is not null;
    public string Freshness => _state.Catalog is null ? "Каталог ещё не проверен" :
        $"Каталог: {_state.Catalog.Freshness}; данные: {(_state.Evidence?.Services.Values.Any(x => x.Freshness == EnrichmentFreshness.Stale) == true ? "устаревшие" : "доступны")}; {_state.LastSuccessfulRefreshAt?.LocalDateTime:g}";
    public string LastCheck => _state.LastCheckAt?.LocalDateTime.ToString("g") ?? "Проверок ещё не было";
    public bool HasUnseenChanges => !_state.ChangesViewed;
    public int CatalogSelectionRevision { get; private set; }
    public int TotalServiceCount => (_state.Catalog?.Services ?? BundledCatalog.Load().Services).Count;
    public int SelectedServiceCount
    {
        get
        {
            var selected = CurrentSelectedIds().ToHashSet(StringComparer.OrdinalIgnoreCase);
            return (_state.Catalog?.Services ?? BundledCatalog.Load().Services).Count(service => selected.Contains(service.Id));
        }
    }

    public async Task LoadAsync()
    {
        var result = await new StateStore().LoadAsync(_statePath);
        _state = result.State;
        if (!File.Exists(_statePath)) await PersistAsync();
        Diagnostics.Clear();
        foreach (var entry in _state.LastDiagnostics) Diagnostics.Add($"{entry.Source}: {entry.Status} — {entry.Message}");
        _isLoaded = true;
        (RefreshCommand as AsyncCommand)?.RaiseCanExecuteChanged();
        if (_state.LastSuccessfulRefreshAt is { } last)
            Status = $"Последняя успешная проверка: {last.LocalDateTime:g}";
        RebuildManual(); RebuildHistory(); RebuildServices(); RebuildExport();
        SignalAll();
    }

    public IReadOnlyList<IPv4Network> ExportRoutes() => _state.ExportRoutes(_state.Mode);

    public async Task RefreshAsync()
    {
        if (IsBusy) return;
        IsBusy = true;
        Error = ""; Status = "Проверка источников…";
        await _mutationGate.WaitAsync();
        try
        {
            var urls = ParseUrls(_state.SourceUrls);
            var candidate = await _pipeline.RunAsync(new RefreshRequest(urls,
                _state.Catalog, _state.Evidence,
                PreviousSourceSnapshots: _state.SourceSnapshots), CancellationToken.None);
            var before = ExportRoutes();
            _state.ApplyRefresh(candidate);
            var next = ExportRoutes();
            var added = RouteSet.Subtract(next, before);
            var removed = RouteSet.Subtract(before, next);
            _state.RecordChange(new ChangeRecord(candidate.CompletedAt, "Проверка источников", added.Count, removed.Count,
                added.Select(x => x.ToString()).ToArray(), removed.Select(x => x.ToString()).ToArray()));
            try { await PersistAsync(); }
            catch { _state = (await new StateStore().LoadAsync(_statePath)).State; throw; }
            Status = $"Источники проверены: {candidate.CompletedAt.LocalDateTime:g}";
            Diagnostics.Clear();
            foreach (var entry in _state.LastDiagnostics) Diagnostics.Add($"{entry.Source}: {entry.Status} — {entry.Message}");
            RebuildServices(); RebuildHistory(); RebuildExport(); SignalAll();
            DataChanged?.Invoke(this, EventArgs.Empty);
        }
        catch (Exception ex)
        {
            if (File.Exists(_statePath))
            {
                try { _state = (await new StateStore().LoadAsync(_statePath)).State; RebuildServices(); RebuildHistory(); RebuildExport(); SignalAll(); }
                catch { /* Report the original operation failure. */ }
            }
            Error = SafeError(ex);
            Status = "Проверка не завершена; предыдущий результат сохранён";
        }
        finally { _mutationGate.Release(); IsBusy = false; }
    }

    public async Task SetModeAsync(ExportMode mode)
    {
        if (_state.Mode == mode) return;
        await MutateAsync(() => _state.Mode = mode);
        RebuildServices(); RebuildExport(); SignalAll();
    }

    public async Task SelectServiceAsync(string id, bool selected)
    {
        if (IsSelected(id) == selected) return;
        await MutateAsync(() =>
        {
            InitializeModeSelection();
            _state.SetSelection(_state.Mode, id, selected);
        });
        foreach (var row in Services.Where(row => row.Id == id)) row.Selected = selected;
        CatalogSelectionRevision++;
        OnPropertyChanged(nameof(CatalogSelectionRevision));
        RebuildExport();
    }

    public async Task SelectAllAsync(bool selected, string? category = null)
    {
        var ids = (_state.Catalog?.Services ?? BundledCatalog.Load().Services)
            .Where(x => category is null || x.Category == category).Select(x => x.Id).ToHashSet();
        await MutateAsync(() =>
        {
            InitializeModeSelection();
            foreach (var id in ids) _state.SetSelection(_state.Mode, id, selected);
        });
        foreach (var row in Services.Where(row => category is null || row.Category == category)) row.Selected = selected;
        CatalogSelectionRevision++;
        OnPropertyChanged(nameof(CatalogSelectionRevision));
        RebuildExport();
    }

    public async Task SetRemainderAsync(bool selected)
    {
        await MutateAsync(() =>
        {
            _state.SetRemainderSelection(_state.Mode, selected);
        });
        RebuildExport();
    }

    public async Task SetManualEnabledAsync(bool enabled)
    {
        await MutateAsync(() => _state.ManualEnabled = enabled);
        RebuildExport();
    }

    public async Task<(int Added, IReadOnlyList<string> Invalid)> AddManualAsync(string input, string group, string note)
    {
        var invalid = new List<string>();
        var values = new List<ManualRoute>();
        foreach (var token in input.Split([',', ';', ' ', '\r', '\n', '\t'], StringSplitOptions.RemoveEmptyEntries | StringSplitOptions.TrimEntries))
        {
            if (IPv4Network.TryParse(token, out var route)) values.Add(new(route.ToString(), group.Trim(), note.Trim()));
            else invalid.Add(token);
        }
        var known = _state.ManualRoutes.Select(x => x.Value).ToHashSet(StringComparer.Ordinal);
        values = values.Where(x => known.Add(x.Value)).ToList();
        if (values.Count > 0) await MutateAsync(() => _state.ManualRoutes.AddRange(values));
        RebuildManual(); RebuildExport();
        return (values.Count, invalid);
    }

    public async Task RemoveManualAsync(string value)
    {
        await MutateAsync(() => _state.ManualRoutes.RemoveAll(x => x.Value == value));
        RebuildManual(); RebuildExport();
    }

    public async Task UpdateManualAsync(string value, string group, string note)
    {
        await MutateAsync(() =>
        {
            var i = _state.ManualRoutes.FindIndex(x => x.Value == value);
            if (i >= 0) _state.ManualRoutes[i] = new ManualRoute(value, group.Trim(), note.Trim());
        });
        RebuildManual();
    }

    public async Task MarkChangesViewedAsync()
    {
        if (_state.ChangesViewed) return;
        await MutateAsync(() => _state.ChangesViewed = true);
        SignalAll();
    }

    public async Task SaveSettingsAsync(IReadOnlyList<string> urls, bool automatic, int hours,
        bool notifications, bool tray, bool closeToTray)
    {
        _ = ParseUrls(urls);
        if (hours is < 1 or > 720) throw new ArgumentOutOfRangeException(nameof(hours));
        await MutateAsync(() =>
        {
            _state.SourceUrls = urls.ToList();
            _state.Automatic = automatic;
            _state.IntervalHours = hours;
            _state.NotificationsEnabled = notifications;
            _state.TrayEnabled = tray;
            _state.CloseToTray = closeToTray;
        });
        SignalAll();
    }
    public bool CloseToTray => _state.CloseToTray;

    public async Task SaveProfileAsync(string name)
    {
        name = name.Trim();
        if (name.Length is 0 or > 80) throw new ArgumentException("Имя профиля: от 1 до 80 символов.");
        await MutateAsync(() => _state.Profiles[name] = new SelectionProfile(name,
            CurrentSelectedIds().ToHashSet(), new HashSet<ExportMode> { _state.Mode }, _state.ManualEnabled,
            _state.RemaindersSelectedByMode.TryGetValue(_state.Mode, out var includeRemainder)
                ? includeRemainder : _state.SelectNewRemainders));
        SignalAll();
    }

    public async Task ApplyProfileAsync(string name)
    {
        if (!_state.Profiles.TryGetValue(name, out var profile)) return;
        await MutateAsync(() =>
        {
            _state.ApplyProfile(name);
            _state.Mode = profile.Modes.FirstOrDefault();
        });
        RebuildServices(); RebuildExport(); SignalAll();
    }

    public async Task DeleteProfileAsync(string name)
    {
        await MutateAsync(() => _state.Profiles.Remove(name));
        SignalAll();
    }

    public byte[] ExportJson() => AmneziaJsonExporter.Serialize(RequireRoutes());
    public string ExportAllowedIPs() => AllowedIPsExporter.Format(RequireRoutes());
    public IReadOnlyList<IPv4Network> RequireRoutes()
    {
        var routes = ExportRoutes();
        if (routes.Count == 0) throw new InvalidOperationException("Нет выбранных маршрутов для выгрузки.");
        return routes;
    }

    public static RefreshSourceUrls ParseUrls(IReadOnlyList<string> urls)
    {
        if (urls.Count != 4) throw new ArgumentException("Нужны четыре HTTPS-адреса источников.");
        var values = urls.Select(x => Uri.TryCreate(x.Trim(), UriKind.Absolute, out var uri) &&
            uri.Scheme == Uri.UriSchemeHttps && uri.UserInfo.Length == 0 ? uri : null).ToArray();
        if (values.Any(x => x is null)) throw new ArgumentException("Каждый источник должен иметь корректный HTTPS-адрес без учётных данных.");
        return new(values[0]!, values[1]!, values[2]!, values[3]!);
    }

    public static string SafeError(Exception ex) => ex switch
    {
        OperationCanceledException => "Время проверки истекло или операция отменена.",
        HttpRequestException => "Источник недоступен. Проверьте сеть и HTTPS-адреса.",
        JsonException or FormatException => "Источник содержит некорректные данные.",
        ArgumentException => "Проверьте введённые адреса и настройки.",
        _ => "Не удалось завершить операцию. Предыдущие данные сохранены."
    };

    private async Task MutateAsync(Action change)
    {
        await _mutationGate.WaitAsync();
        try
        {
            try { change(); await PersistAsync(); }
            catch
            {
                _state = (await new StateStore().LoadAsync(_statePath)).State;
                RebuildServices(); RebuildManual(); RebuildHistory(); RebuildExport(); SignalAll();
                throw;
            }
            DataChanged?.Invoke(this, EventArgs.Empty);
        }
        finally { _mutationGate.Release(); }
    }

    private Task PersistAsync()
    {
        var routes = ExportRoutes();
        var bytes = routes.Count == 0 ? "[]"u8.ToArray() : AmneziaJsonExporter.Serialize(routes);
        return _persistence.CommitAsync(_state, _statePath, _exportPath, bytes);
    }

    private void InitializeModeSelection()
    {
        if (_state.SelectionInitializedByMode.GetValueOrDefault(_state.Mode)) return;
        _state.SelectedServiceIdsByMode[_state.Mode] = _state.SelectedServiceIds.Count > 0
            ? _state.SelectedServiceIds.ToList()
            : (_state.Catalog?.Services ?? BundledCatalog.Load().Services).Select(x => x.Id).ToList();
        _state.SelectionInitializedByMode[_state.Mode] = true;
    }

    private IReadOnlyList<string> CurrentSelectedIds()
    {
        if (_state.SelectionInitializedByMode.GetValueOrDefault(_state.Mode) &&
            _state.SelectedServiceIdsByMode.TryGetValue(_state.Mode, out var ids)) return ids;
        if (_state.SelectedServiceIds.Count > 0) return _state.SelectedServiceIds;
        return (_state.Catalog?.Services ?? BundledCatalog.Load().Services).Select(x => x.Id).ToArray();
    }

    private bool IsSelected(string id) => CurrentSelectedIds().Contains(id, StringComparer.OrdinalIgnoreCase);

    private void RebuildServices()
    {
        Services.Clear();
        var catalog = _state.Catalog ?? BundledCatalog.Load();
        var selected = CurrentSelectedIds().ToHashSet(StringComparer.OrdinalIgnoreCase);
        foreach (var service in catalog.Services.Where(MatchesService)
                     .OrderBy(s => s.Category).ThenBy(s => s.Name))
        {
            var evidence = _state.Evidence?.For(service.Id);
            IReadOnlyList<IPv4Network> ownedRoutes = _state.MatchedRoutesByMode.TryGetValue(_state.Mode, out var byService) &&
                byService.TryGetValue(service.Id, out var foundRoutes) ? foundRoutes : Array.Empty<IPv4Network>();
            Services.Add(new ServiceRow
            {
                Id = service.Id, Name = service.Name, Category = service.Category,
                Selected = selected.Contains(service.Id),
                RouteCount = ownedRoutes.Count,
                Evidence = evidence is null ? "Без сетевых данных" : $"{evidence.Freshness} · DNS {evidence.DnsUpdatedAt?.LocalDateTime:g} · ASN {evidence.AsnUpdatedAt?.LocalDateTime:g}",
                Details = $"Домены: {string.Join(", ", service.Domains)}\nASN: {string.Join(", ", service.Asns.Select(x => $"AS{x}"))}\nМаршруты: {string.Join(", ", ownedRoutes)}"
            });
        }
    }

    private bool MatchesService(CatalogService service)
    {
        if (CatalogSearch.Matches(service, _search, _state.Mode)) return true;
        if (!_state.MatchedRoutesByMode.TryGetValue(_state.Mode, out var byService) ||
            !byService.TryGetValue(service.Id, out var routes)) return false;
        if (IPv4Network.TryParse(_search, out var query)) return routes.Any(x => x.Intersects(query));
        return routes.Any(x => x.ToString().Contains(_search, StringComparison.OrdinalIgnoreCase));
    }

    private void RebuildManual()
    {
        ManualRoutes.Clear();
        foreach (var route in _state.ManualRoutes) ManualRoutes.Add(new ManualRow { Value = route.Value, Group = route.Group ?? "", Note = route.Note ?? "" });
    }
    private void RebuildHistory()
    {
        History.Clear();
        foreach (var record in _state.History.OrderByDescending(x => x.At).Take(100)) History.Add(record);
    }
    private void RebuildExport()
    {
        var routes = ExportRoutes();
        if (routes.Count == 0) RoutesText = "Нет выбранных маршрутов.";
        else
        {
            var owners = Enumerable.Range(0, routes.Count).Select(_ => new HashSet<string>()).ToArray();
            void AddOwner(IPv4Network source, string name)
            {
                var low = 0; var high = routes.Count - 1; var index = -1;
                while (low <= high)
                {
                    var middle = low + (high - low) / 2;
                    if (routes[middle].Network <= source.Network) { index = middle; low = middle + 1; }
                    else high = middle - 1;
                }
                if (index >= 0 && routes[index].Contains(source)) owners[index].Add(name);
            }
            if (_state.MatchedRoutesByMode.TryGetValue(_state.Mode, out var byService))
            {
                var names = (_state.Catalog?.Services ?? []).ToDictionary(x => x.Id, x => x.Name);
                foreach (var id in CurrentSelectedIds())
                    if (byService.TryGetValue(id, out var owned))
                        foreach (var route in owned) AddOwner(route, names.GetValueOrDefault(id, id));
            }
            if ((!_state.RemaindersSelectedByMode.TryGetValue(_state.Mode, out var include) ? _state.SelectNewRemainders : include) &&
                _state.UnassignedRoutesByMode.TryGetValue(_state.Mode, out var remainder))
                foreach (var route in remainder) AddOwner(route, "Остальные сети источника");
            if (_state.ManualEnabled)
                foreach (var manual in _state.ManualRoutes)
                    if (IPv4Network.TryParse(manual.Value, out var route)) AddOwner(route, "Мои IP");
            RoutesText = string.Join(Environment.NewLine, routes.Select((route, i) =>
                $"{route}    ·    {string.Join(", ", owners[i].Order(StringComparer.CurrentCulture))}"));
        }
        OnPropertyChanged(nameof(RouteCount)); OnPropertyChanged(nameof(AddressCount));
    }
    public int RouteCount => ExportRoutes().Count;
    public ulong AddressCount => ExportRoutes().Aggregate(0UL, (sum, route) => checked(sum + route.AddressCount));
    private void SignalAll()
    {
        foreach (var name in new[] { nameof(Mode), nameof(Freshness), nameof(LastCheck), nameof(HasUnseenChanges), nameof(State), nameof(HasActiveCatalog) }) OnPropertyChanged(name);
    }
    private void Set<T>(ref T field, T value, [CallerMemberName] string? name = null)
    {
        if (EqualityComparer<T>.Default.Equals(field, value)) return;
        field = value; OnPropertyChanged(name);
    }
    private void OnPropertyChanged(string? name) => PropertyChanged?.Invoke(this, new(name));
}

public sealed class AsyncCommand(Func<Task> execute, Func<bool> canExecute) : ICommand
{
    public event EventHandler? CanExecuteChanged;
    public bool CanExecute(object? parameter) => canExecute();
    public async void Execute(object? parameter) => await execute();
    public void RaiseCanExecuteChanged() => CanExecuteChanged?.Invoke(this, EventArgs.Empty);
}
