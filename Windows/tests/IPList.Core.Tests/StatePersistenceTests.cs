using IPList.Core.Catalog;
using IPList.Core.State;

namespace IPList.Core.Tests;

public sealed class StatePersistenceTests
{
    [Fact]
    public async Task SavesAndLoadsStateWithoutLosingUserChoices()
    {
        using var temp = new TempDirectory();
        var path = Path.Combine(temp.Path, "nested", "state.json");
        var state = new AppState
        {
            Mode = ExportMode.Lite,
            ManualEnabled = false,
            ManualRoutes = [new("192.0.2.0/24", "test", "offline sample")],
            SelectedServiceIds = ["sample-service"],
            SelectedRemainders = ["192.0.2.0/24"],
            Profiles = new Dictionary<string, SelectionProfile>(StringComparer.OrdinalIgnoreCase)
            {
                ["Home"] = new("Home", new HashSet<string>(["sample-service"]), new HashSet<ExportMode>([ExportMode.Lite]), false)
            }
        };
        var store = new StateStore();

        await store.SaveAsync(state, path);
        var loaded = await store.LoadAsync(path);

        Assert.False(loaded.Migrated);
        Assert.Equal(1, loaded.State.SchemaVersion);
        Assert.Equal(ExportMode.Lite, loaded.State.Mode);
        Assert.False(loaded.State.ManualEnabled);
        Assert.Equal(state.ManualRoutes, loaded.State.ManualRoutes);
        Assert.Equal(state.SelectedServiceIds, loaded.State.SelectedServiceIds);
        Assert.Equal(state.SelectedRemainders, loaded.State.SelectedRemainders);
        Assert.Contains("Home", loaded.State.Profiles.Keys);
    }

    [Fact]
    public async Task MissingStateLoadsDefaultsAndLegacySchemaIsMarkedForMigration()
    {
        using var temp = new TempDirectory();
        var store = new StateStore();
        var missing = await store.LoadAsync(Path.Combine(temp.Path, "missing.json"));
        Assert.False(missing.Migrated);
        Assert.Equal(1, missing.State.SchemaVersion);

        var legacyPath = Path.Combine(temp.Path, "legacy", "state.json");
        Directory.CreateDirectory(Path.GetDirectoryName(legacyPath)!);
        var legacyBytes = "{\"schemaVersion\":0,\"selectedServiceIds\":[\"sample-service\"]}"u8.ToArray();
        await File.WriteAllBytesAsync(legacyPath, legacyBytes);
        var legacy = await store.LoadAsync(legacyPath);
        Assert.True(legacy.Migrated);
        Assert.Equal(Path.Combine(Path.GetDirectoryName(legacyPath)!, "state-before-v1.4.json"), legacy.BackupPath);
        Assert.Equal(legacyBytes, await File.ReadAllBytesAsync(legacy.BackupPath!));
    }

    [Fact]
    public async Task CoordinatorCommitsStateAndAutosavedExportTogether()
    {
        using var temp = new TempDirectory();
        var statePath = Path.Combine(temp.Path, "state.json");
        var exportPath = Path.Combine(temp.Path, "amnezia-direct.json");
        var payload = "[{\"ip\":\"192.0.2.0/24\"}]"u8.ToArray();
        var state = new AppState { Mode = ExportMode.Full, SelectedServiceIds = ["sample"] };

        await new AppPersistenceCoordinator(new StateStore(), new AutosavedExportStore())
            .CommitAsync(state, statePath, exportPath, payload);

        var savedState = await new StateStore().LoadAsync(statePath);
        Assert.Equal(ExportMode.Full, savedState.State.Mode);
        Assert.Equal(payload, await File.ReadAllBytesAsync(exportPath));
    }

    [Fact]
    public async Task FailedCoordinatorCommitRemovesNewStateFile()
    {
        using var temp = new TempDirectory();
        var statePath = Path.Combine(temp.Path, "state.json");
        var exportPath = Path.Combine(temp.Path, "is-a-directory");
        Directory.CreateDirectory(exportPath);
        var coordinator = new AppPersistenceCoordinator(new StateStore(), new AutosavedExportStore());

        await Assert.ThrowsAnyAsync<IOException>(() => coordinator.CommitAsync(new AppState(), statePath,
            exportPath, "[]"u8.ToArray()));

        Assert.False(File.Exists(statePath));
    }
}
