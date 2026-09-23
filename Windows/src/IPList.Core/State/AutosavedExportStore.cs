namespace IPList.Core.State;

public sealed class AutosavedExportStore
{
    public Task SaveAsync(string path, byte[] data, CancellationToken cancellationToken = default) =>
        AtomicFile.WriteAsync(path, data, cancellationToken);
}

public sealed class AppPersistenceCoordinator(StateStore stateStore, AutosavedExportStore exportStore)
{
    public async Task CommitAsync(AppState state, string statePath, string exportPath, byte[] exportBytes,
        CancellationToken cancellationToken = default)
    {
        var oldState = File.Exists(statePath) ? await File.ReadAllBytesAsync(statePath, cancellationToken).ConfigureAwait(false) : null;
        var oldExport = File.Exists(exportPath) ? await File.ReadAllBytesAsync(exportPath, cancellationToken).ConfigureAwait(false) : null;
        try
        {
            await stateStore.SaveAsync(state, statePath, cancellationToken).ConfigureAwait(false);
            await exportStore.SaveAsync(exportPath, exportBytes, cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            if (oldState is not null) await AtomicFile.WriteAsync(statePath, oldState, CancellationToken.None).ConfigureAwait(false);
            if (oldExport is not null) await AtomicFile.WriteAsync(exportPath, oldExport, CancellationToken.None).ConfigureAwait(false);
            throw;
        }
    }
}
