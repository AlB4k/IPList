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
        => await CommitCoreAsync(state, statePath, exportPath, exportBytes, null, cancellationToken).ConfigureAwait(false);

    public Task CommitAsync(AppState state, string statePath, string exportPath, byte[] exportBytes,
        byte[] rawLegacyBytes, CancellationToken cancellationToken = default)
        => CommitCoreAsync(state, statePath, exportPath, exportBytes, rawLegacyBytes, cancellationToken);

    private async Task CommitCoreAsync(AppState state, string statePath, string exportPath, byte[] exportBytes,
        byte[]? rawLegacyBytes, CancellationToken cancellationToken)
    {
        var oldState = File.Exists(statePath) ? await File.ReadAllBytesAsync(statePath, cancellationToken).ConfigureAwait(false) : null;
        var oldExport = File.Exists(exportPath) ? await File.ReadAllBytesAsync(exportPath, cancellationToken).ConfigureAwait(false) : null;
        try
        {
            if (rawLegacyBytes is null)
                await stateStore.SaveAsync(state, statePath, cancellationToken).ConfigureAwait(false);
            else
                await stateStore.SaveAsync(state, statePath, rawLegacyBytes, cancellationToken).ConfigureAwait(false);
            await exportStore.SaveAsync(exportPath, exportBytes, cancellationToken).ConfigureAwait(false);
        }
        catch
        {
            try
            {
                if (oldState is not null) await AtomicFile.WriteAsync(statePath, oldState, CancellationToken.None).ConfigureAwait(false);
                else if (File.Exists(statePath)) File.Delete(statePath);
            }
            catch { /* Preserve the original commit failure. */ }
            try
            {
                if (oldExport is not null) await AtomicFile.WriteAsync(exportPath, oldExport, CancellationToken.None).ConfigureAwait(false);
                else if (File.Exists(exportPath)) File.Delete(exportPath);
            }
            catch { /* Preserve the original commit failure. */ }
            throw;
        }
    }
}
