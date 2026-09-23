using IPList.Core.Catalog;
using IPList.Core.Networking;
using IPList.Core.Refresh;
using IPList.Core.State;

namespace IPList.Core.Tests;

public sealed class AppStateSelectionTests
{
    [Fact]
    public async Task SavedCatalogAndMatchedRoutesRestoreAfterRestart()
    {
        using var temp = new TempDirectory();
        var path = Path.Combine(temp.Path, "state.json");
        var route = IPv4Network.Parse("198.51.100.0/24");
        var service = Service("saved", "198.51.100.1");
        var state = new AppState
        {
            Catalog = new ServiceCatalog([service]),
            MatchedRoutesByMode = new()
            {
                [ExportMode.Targeted] = new(StringComparer.OrdinalIgnoreCase)
                {
                    ["saved"] = [route]
                }
            },
            SelectedServiceIdsByMode = new() { [ExportMode.Targeted] = ["saved"] },
            SelectionInitializedByMode = new() { [ExportMode.Targeted] = true }
        };
        await new StateStore().SaveAsync(state, path);

        var loaded = (await new StateStore().LoadAsync(path)).State;

        Assert.Equal(route, Assert.Single(loaded.MatchedRoutesByMode[ExportMode.Targeted]["saved"]));
        Assert.Equal(route, Assert.Single(loaded.ExportRoutes(ExportMode.Targeted)));
        Assert.Equal(IPv4Network.Parse("198.51.100.1"),
            Assert.Single(loaded.Catalog!.Services.Single().TargetedAddresses));
    }

    [Fact]
    public async Task FirstRefreshAfterReloadKeepsDeselectedKnownServiceAndAddsOnlyNewService()
    {
        using var temp = new TempDirectory();
        var path = Path.Combine(temp.Path, "state.json");
        var existing = Service("existing", "192.0.2.1");
        var deselected = Service("deselected", "192.0.2.2");
        var state = new AppState
        {
            Catalog = new ServiceCatalog([existing, deselected], CatalogFreshness.Bundled),
            SelectedServiceIds = ["existing"],
            SelectedServiceIdsByMode = new() { [ExportMode.Targeted] = ["existing"] },
            SelectionInitializedByMode = new() { [ExportMode.Targeted] = true },
            SelectNewServices = true
        };
        await new StateStore().SaveAsync(state, path);

        var loaded = (await new StateStore().LoadAsync(path)).State;
        Assert.Equal(IPv4Network.Parse("192.0.2.2"),
            Assert.Single(loaded.Catalog!.Services.Single(service => service.Id == "deselected").TargetedAddresses));
        loaded.ApplyRefresh(Transaction(existing, deselected, Service("new", "192.0.2.3")));

        Assert.Equal(new[] { "existing", "new" }, loaded.SelectedServiceIdsByMode[ExportMode.Targeted]);
        Assert.Equal(new[] { IPv4Network.Parse("192.0.2.1"), IPv4Network.Parse("192.0.2.3") },
            loaded.ExportRoutes(ExportMode.Targeted));
    }

    [Fact]
    public void FirstRefreshUsesLegacyInventoryToKeepDeselection()
    {
        var existing = Service("existing", "192.0.2.1");
        var deselected = Service("deselected", "192.0.2.2");
        var state = new AppState
        {
            LegacyServices = [existing, deselected],
            SelectedServiceIds = ["existing"],
            SelectedServiceIdsByMode = new() { [ExportMode.Targeted] = ["existing"] },
            SelectionInitializedByMode = new() { [ExportMode.Targeted] = true }
        };

        state.ApplyRefresh(Transaction(existing, deselected, Service("new", "192.0.2.3")));

        Assert.Equal(new[] { "existing", "new" }, state.SelectedServiceIdsByMode[ExportMode.Targeted]);
    }

    [Fact]
    public void FirstRefreshPromotesLegacySelectionWithoutReenablingKnownService()
    {
        var existing = Service("existing", "192.0.2.1");
        var deselected = Service("deselected", "192.0.2.2");
        var state = new AppState
        {
            Catalog = new ServiceCatalog([existing, deselected]),
            SelectedServiceIds = ["existing"]
        };

        state.ApplyRefresh(Transaction(existing, deselected, Service("new", "192.0.2.3")));

        Assert.Equal(new[] { "existing", "new" }, state.SelectedServiceIdsByMode[ExportMode.Targeted]);
    }

    [Fact]
    public void RenameRecoversSelectedServiceEvenWhenNewServicesAreDisabled()
    {
        var prior = new CatalogService("old", "Old", "Test", ["same.example"], [64500], []);
        var renamed = new CatalogService("renamed", "New", "Test", ["same.example"], [64500], []);
        var state = new AppState
        {
            Catalog = new ServiceCatalog([prior]),
            SelectedServiceIdsByMode = new() { [ExportMode.Targeted] = ["old"] },
            SelectionInitializedByMode = new() { [ExportMode.Targeted] = true },
            SelectNewServices = false
        };

        state.ApplyRefresh(Transaction(renamed));

        Assert.Equal(new[] { "renamed" }, state.SelectedServiceIdsByMode[ExportMode.Targeted]);
    }

    [Fact]
    public void RenamePreservesDeselectionWhenNewServicesAreAutoSelected()
    {
        var prior = new CatalogService("old", "Old", "Test", ["same.example"], [], []);
        var renamed = new CatalogService("renamed", "New", "Test", ["same.example"], [], []);
        var state = new AppState
        {
            Catalog = new ServiceCatalog([prior]),
            SelectedServiceIdsByMode = new() { [ExportMode.Targeted] = [] },
            SelectionInitializedByMode = new() { [ExportMode.Targeted] = true }
        };

        state.ApplyRefresh(Transaction(renamed, new CatalogService("unrelated", "New", "Test", ["else.example"], [], [])));

        Assert.Equal(new[] { "unrelated" }, state.SelectedServiceIdsByMode[ExportMode.Targeted]);
    }

    [Fact]
    public void RenameCanRecoverByUniqueAsnWithoutSharedDomain()
    {
        var prior = new CatalogService("old", "Old", "Test", ["old.example"], [64500], []);
        var renamed = new CatalogService("renamed", "New", "Test", ["new.example"], [64500], []);
        var state = new AppState
        {
            Catalog = new ServiceCatalog([prior]),
            SelectedServiceIdsByMode = new() { [ExportMode.Lite] = ["old"] },
            SelectionInitializedByMode = new() { [ExportMode.Lite] = true },
            SelectNewServices = false
        };

        state.ApplyRefresh(Transaction(ExportMode.Lite, renamed));

        Assert.Equal(new[] { "renamed" }, state.SelectedServiceIdsByMode[ExportMode.Lite]);
    }

    [Fact]
    public void AmbiguousRenameStaysDeselectedAndEmitsDiagnostic()
    {
        var first = new CatalogService("first", "First", "Test", ["shared.example"], [], []);
        var second = new CatalogService("second", "Second", "Test", ["shared.example"], [], []);
        var renamed = new CatalogService("renamed", "New", "Test", ["shared.example"], [], []);
        var state = new AppState
        {
            Catalog = new ServiceCatalog([first, second]),
            SelectedServiceIdsByMode = new() { [ExportMode.Targeted] = ["first"] },
            SelectionInitializedByMode = new() { [ExportMode.Targeted] = true }
        };

        state.ApplyRefresh(Transaction(renamed));

        Assert.Empty(state.SelectedServiceIdsByMode[ExportMode.Targeted]);
        Assert.Contains(state.LastDiagnostics, diagnostic => diagnostic.Status == "ambiguous" &&
            diagnostic.Source == "selection");
    }

    [Fact]
    public void NewIdSharingAnExistingServiceIdentityStaysDeselected()
    {
        var existing = new CatalogService("existing", "Existing", "Test", ["shared.example"], [], []);
        var duplicate = new CatalogService("duplicate", "Duplicate", "Test", ["shared.example"], [], []);
        var state = new AppState
        {
            Catalog = new ServiceCatalog([existing]),
            SelectedServiceIdsByMode = new() { [ExportMode.Targeted] = ["existing"] },
            SelectionInitializedByMode = new() { [ExportMode.Targeted] = true }
        };

        state.ApplyRefresh(Transaction(existing, duplicate));

        Assert.Equal(new[] { "existing" }, state.SelectedServiceIdsByMode[ExportMode.Targeted]);
        Assert.Contains(state.LastDiagnostics, diagnostic => diagnostic.Status == "ambiguous" &&
            diagnostic.Message.Contains("duplicate", StringComparison.Ordinal));
    }

    private static CatalogService Service(string id, string address) => new(id, id, "Test", [], [], [])
    {
        TargetedAddresses = [IPv4Network.Parse(address)]
    };

    private static RefreshTransaction Transaction(params CatalogService[] services)
        => Transaction(ExportMode.Targeted, services);

    private static RefreshTransaction Transaction(ExportMode mode, params CatalogService[] services)
    {
        var catalog = new ServiceCatalog(services);
        IReadOnlyDictionary<string, IReadOnlyList<IPv4Network>> routes = services.ToDictionary(
            service => service.Id, service => service.TargetedAddresses, StringComparer.OrdinalIgnoreCase);
        IReadOnlyDictionary<ExportMode, IReadOnlyDictionary<string, IReadOnlyList<IPv4Network>>> byMode =
            new Dictionary<ExportMode, IReadOnlyDictionary<string, IReadOnlyList<IPv4Network>>>
            { [mode] = routes };
        var matched = new MatchedCatalog(catalog, byMode,
            new Dictionary<ExportMode, IReadOnlyList<IPv4Network>>(), [], EnrichmentFreshness.Fresh);
        var now = DateTimeOffset.UtcNow;
        return new RefreshTransaction(matched,
            new EnrichmentSnapshot(now, "test", new Dictionary<string, ServiceEnrichment>()), [],
            new Dictionary<ExportMode, SourceSnapshot>(), now);
    }
}
