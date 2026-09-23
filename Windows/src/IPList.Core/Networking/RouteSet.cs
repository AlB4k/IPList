namespace IPList.Core.Networking;

public static class RouteSet
{
    public static IReadOnlyList<IPv4Network> Normalize(IEnumerable<IPv4Network> input, int limit = IPv4Network.MaximumFragments)
    {
        if (limit < 0) throw new ArgumentOutOfRangeException(nameof(limit));
        var sorted = input.Distinct().Order().ToList();
        var result = new List<IPv4Network>();
        foreach (var network in sorted)
        {
            if (result.Count > 0 && result[^1].Contains(network)) continue;
            while (result.Count > 0 && network.Contains(result[^1])) result.RemoveAt(result.Count - 1);
            result.Add(network);
            while (result.Count >= 2)
            {
                var right = result[^1];
                var left = result[^2];
                if (left.Prefix == 0 || left.Prefix != right.Prefix ||
                    (ulong)left.LastAddress + 1 != right.Network ||
                    IPv4Network.Create(left.Network, left.Prefix - 1).Network != left.Network) break;
                result.RemoveRange(result.Count - 2, 2);
                result.Add(IPv4Network.Create(left.Network, left.Prefix - 1));
            }
            if (result.Count > limit) throw new InvalidOperationException("CIDR fragment limit exceeded.");
        }
        return result;
    }

    public static IReadOnlyList<IPv4Network> Subtract(IEnumerable<IPv4Network> sources, IEnumerable<IPv4Network> exclusions, int limit = IPv4Network.MaximumFragments)
    {
        var sourceRoutes = Normalize(sources, limit);
        var excludedRoutes = Normalize(exclusions, limit);
        var remainder = new List<IPv4Network>();
        var start = 0;
        foreach (var source in sourceRoutes)
        {
            while (start < excludedRoutes.Count && excludedRoutes[start].LastAddress < source.Network) start++;
            var fragments = new List<IPv4Network> { source };
            for (var index = start; index < excludedRoutes.Count && excludedRoutes[index].Network <= source.LastAddress; index++)
            {
                var next = new List<IPv4Network>();
                foreach (var route in fragments) next.AddRange(route.Subtract(excludedRoutes[index], limit));
                if (next.Count > limit) throw new InvalidOperationException("CIDR fragment limit exceeded.");
                fragments = next;
                if (fragments.Count == 0) break;
            }
            remainder.AddRange(fragments);
            if (remainder.Count > limit) throw new InvalidOperationException("CIDR fragment limit exceeded.");
        }
        return Normalize(remainder, limit);
    }

    public static bool UnionEquals(IEnumerable<IPv4Network> left, IEnumerable<IPv4Network> right, int limit = IPv4Network.MaximumFragments)
    {
        var a = Normalize(left, limit);
        var b = Normalize(right, limit);
        return Subtract(a, b, limit).Count == 0 && Subtract(b, a, limit).Count == 0;
    }
}
