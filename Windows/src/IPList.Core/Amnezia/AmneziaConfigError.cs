namespace IPList.Core.Amnezia;

public sealed class AmneziaConfigError(string message) : FormatException(message);
public enum AllowedIPsOperation { Add, Replace, Bypass }
