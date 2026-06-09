/// M3U playlist parser for IPTV streams
class M3uEntry {
  final String tvgId;
  final String name;
  final String logo;
  final String category;
  final String language;
  final String country;
  final String url;

  M3uEntry({
    this.tvgId = '',
    this.name = '',
    this.logo = '',
    this.category = '',
    this.language = '',
    this.country = '',
    required this.url,
  });
}

class M3uParser {
  /// Parse M3U text content into a list of entries
  static List<M3uEntry> parse(String text) {
    final entries = <M3uEntry>[];
    if (text.isEmpty) return entries;

    final lines = text.split('\n');

    for (int i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (!line.startsWith('#EXTINF:')) continue;

      final tvgId = _extractAttr(line, 'tvg-id');
      final tvgName = _extractAttr(line, 'tvg-name');
      final tvgLogo = _extractAttr(line, 'tvg-logo');
      final group = _extractAttr(line, 'group-title');
      final lang = _extractAttr(line, 'tvg-language') ??
          _extractAttr(line, 'language') ??
          '';
      final country = _extractAttr(line, 'tvg-country') ??
          _extractAttr(line, 'country') ??
          '';

      // Display name is after the last comma
      final commaIdx = line.lastIndexOf(',');
      final displayName =
          commaIdx != -1 ? line.substring(commaIdx + 1).trim() : '';

      // URL is on the next non-empty, non-comment line
      String url = '';
      for (int j = i + 1; j < lines.length; j++) {
        final nextLine = lines[j].trim();
        if (nextLine.isEmpty || nextLine.startsWith('#')) continue;
        url = nextLine;
        break;
      }

      if (url.isNotEmpty) {
        entries.add(M3uEntry(
          tvgId: tvgId ?? '',
          name: tvgName ?? displayName,
          logo: tvgLogo ?? '',
          category: group ?? '',
          language: lang,
          country: country,
          url: url,
        ));
      }
    }

    return entries;
  }

  static String? _extractAttr(String line, String attr) {
    final regex = RegExp('$attr="([^"]*)"');
    final match = regex.firstMatch(line);
    return match?.group(1);
  }
}
