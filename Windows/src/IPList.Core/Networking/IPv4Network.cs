using System.Globalization;

namespace IPList.Core.Networking;

public readonly record struct IPv4Network : IComparable<IPv4Network>
{
    public const int MaximumFragments = 250_000;
    public uint Network { get; }
    public int Prefix { get; }
    public uint LastAddress => Network | ~Mask(Prefix);
    public ulong AddressCount => 1UL << (32 - Prefix);

    private IPv4Network(uint address, int prefix)
    {
        Network = address & Mask(prefix);
        Prefix = prefix;
    }

    public static bool TryParse(string? text, out IPv4Network result)
    {
        result = default;
        if (text is null) return false;
        var parts = text.Trim().Split('/');
        if (parts.Length is < 1 or > 2) return false;
        var octets = parts[0].Split('.');
        if (octets.Length != 4) return false;
        uint address = 0;
        foreach (var octet in octets)
        {
            if (octet.Length is < 1 or > 3 || (octet.Length > 1 && octet[0] == '0') ||
                !octet.All(c => c is >= '0' and <= '9') ||
                !byte.TryParse(octet, NumberStyles.None, CultureInfo.InvariantCulture, out var value)) return false;
            address = (address << 8) | value;
        }
        var prefix = 32;
        if (parts.Length == 2 && (!int.TryParse(parts[1], NumberStyles.None, CultureInfo.InvariantCulture, out prefix) || prefix is < 0 or > 32)) return false;
        result = new IPv4Network(address, prefix);
        return true;
    }

    public static IPv4Network Parse(string text) => TryParse(text, out var network)
        ? network : throw new FormatException("Invalid IPv4 network.");

    internal static IPv4Network Create(uint address, int prefix) => new(address, prefix);
    private static uint Mask(int prefix) => prefix == 0 ? 0 : uint.MaxValue << (32 - prefix);
    public bool Contains(IPv4Network other) => Network <= other.Network && LastAddress >= other.LastAddress;
    public bool Contains(uint address) => Network <= address && address <= LastAddress;
    public bool Intersects(IPv4Network other) => Network <= other.LastAddress && other.Network <= LastAddress;
    public IPv4Network? Intersect(IPv4Network other) => !Intersects(other) ? null : Contains(other) ? other : this;

    public IReadOnlyList<IPv4Network> Subtract(IPv4Network other, int limit = MaximumFragments)
    {
        if (limit < 0) throw new ArgumentOutOfRangeException(nameof(limit));
        if (!Intersects(other)) return limit == 0 ? throw new InvalidOperationException("CIDR fragment limit exceeded.") : [this];
        if (other.Contains(this)) return [];
        var output = new List<IPv4Network>();
        var current = this;
        while (current != other)
        {
            var childPrefix = current.Prefix + 1;
            var half = 1u << (32 - childPrefix);
            var left = Create(current.Network, childPrefix);
            var right = Create(current.Network + half, childPrefix);
            if (left.Contains(other)) { output.Add(right); current = left; }
            else { output.Add(left); current = right; }
            if (output.Count > limit) throw new InvalidOperationException("CIDR fragment limit exceeded.");
        }
        output.Sort();
        return output;
    }

    public int CompareTo(IPv4Network other)
    {
        var comparison = Network.CompareTo(other.Network);
        return comparison == 0 ? Prefix.CompareTo(other.Prefix) : comparison;
    }

    public override string ToString() => $"{Network >> 24}.{(Network >> 16) & 255}.{(Network >> 8) & 255}.{Network & 255}/{Prefix}";
}
