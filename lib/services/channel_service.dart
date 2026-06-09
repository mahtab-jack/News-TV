import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:flutter/material.dart';
import '../models/channel.dart';
import '../utils/m3u_parser.dart';

/// Category definition
class ChannelCategory {
  final String id;
  final String name;
  final IconData icon;
  const ChannelCategory({required this.id, required this.name, required this.icon});
}

/// Service for managing channel data and playlist loading
class ChannelService {
  static const List<ChannelCategory> categories = [
    ChannelCategory(id: 'all', name: 'All Channels', icon: Icons.grid_view_rounded),
    ChannelCategory(id: 'favorites', name: 'Favorites', icon: Icons.favorite_rounded),
    ChannelCategory(id: 'hindi-news', name: 'Hindi News', icon: Icons.newspaper_rounded),
    ChannelCategory(id: 'english-news', name: 'English News', icon: Icons.language_rounded),
    ChannelCategory(id: 'regional', name: 'Regional', icon: Icons.map_rounded),
    ChannelCategory(id: 'international', name: 'International', icon: Icons.public_rounded),
    ChannelCategory(id: 'business', name: 'Business', icon: Icons.trending_up_rounded),
    ChannelCategory(id: 'movies', name: 'Movies', icon: Icons.movie_rounded),
    ChannelCategory(id: 'music', name: 'Music', icon: Icons.music_note_rounded),
    ChannelCategory(id: 'sports', name: 'Sports', icon: Icons.sports_kabaddi_rounded),
  ];

  static const Map<String, String> _playlistUrls = {
    'india': 'https://iptv-org.github.io/iptv/countries/in.m3u',
    'news': 'https://iptv-org.github.io/iptv/categories/news.m3u',
    'business': 'https://iptv-org.github.io/iptv/categories/business.m3u',
    'movies': 'https://iptv-org.github.io/iptv/categories/movies.m3u',
    'music': 'https://iptv-org.github.io/iptv/categories/music.m3u',
    'sports': 'https://iptv-org.github.io/iptv/categories/sports.m3u',
  };

  final List<Channel> channels = [];
  final String serverBase;
  bool _loaded = false;

  ChannelService({this.serverBase = 'http://localhost:8080'});

  bool get isLoaded => _loaded;

  /// Initialize with predefined channels
  void initPredefined() {
    channels.clear();
    channels.addAll(_predefinedChannels);
  }

  /// Load all playlists and match streams to channels
  Future<int> loadAllPlaylists() async {
    int totalAdded = 0;
    for (final entry in _playlistUrls.entries) {
      try {
        final added = await _loadPlaylist(entry.key, entry.value);
        totalAdded += added;
        debugPrint('[ChannelService] ${entry.key}: matched $added streams');
      } catch (e) {
        debugPrint('[ChannelService] Failed to load ${entry.key}: $e');
      }
    }
    _loaded = true;
    _reindex();
    return totalAdded;
  }

  Future<int> _loadPlaylist(String type, String directUrl) async {
    String text = '';

    // Try server proxy first, then direct
    try {
      final proxyUrl = '$serverBase/api/playlist/$type';
      final response = await http.get(Uri.parse(proxyUrl))
          .timeout(const Duration(seconds: 10));
      if (response.statusCode == 200) {
        text = response.body;
      }
    } catch (_) {}

    if (text.isEmpty) {
      try {
        final response = await http.get(Uri.parse(directUrl))
            .timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          text = response.body;
        }
      } catch (_) {}
    }

    if (text.isEmpty) return 0;

    final entries = M3uParser.parse(text);
    return _matchChannels(entries, type);
  }

  int _matchChannels(List<M3uEntry> entries, String playlistType) {
    int addedCount = 0;

    for (final entry in entries) {
      if (entry.url.isEmpty) continue;

      // Try to match to existing channel
      final existing = channels.cast<Channel?>().firstWhere(
        (ch) {
          if (ch == null) return false;
          final chNorm = ch.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');
          final entNorm = entry.name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

          if (ch.streamUrl != null && ch.streamUrl == entry.url) return true;
          if (ch.tvgId.isNotEmpty && entry.tvgId.isNotEmpty && ch.tvgId == entry.tvgId) return true;
          if (chNorm == entNorm) return true;
          if (chNorm.length > 3 && entNorm.length > 3) {
            if (chNorm.contains(entNorm) || entNorm.contains(chNorm)) {
              if (ch.language.toLowerCase() == entry.language.toLowerCase() || entry.language.isEmpty) {
                return true;
              }
            }
          }
          return false;
        },
        orElse: () => null,
      );

      if (existing != null) {
        if (existing.streamUrl == null || existing.streamUrl!.isEmpty) {
          existing.streamUrl = entry.url;
          addedCount++;
        }
        if (entry.logo.isNotEmpty && existing.logo.isEmpty) {
          existing.logo = entry.logo;
        }
        if (!existing.alternativeUrls.contains(entry.url) && existing.streamUrl != entry.url) {
          existing.alternativeUrls = [...existing.alternativeUrls, entry.url];
        }
        continue;
      }

      // Auto-detect language and category for dynamic channels
      String lang = entry.language;
      String country = entry.country;
      String category = _detectCategory(entry, playlistType);

      if (lang.isEmpty) {
        lang = _detectLanguage(entry.name, entry.category);
      }
      if (country.isEmpty && lang != 'English') {
        country = 'IN';
      }

      // Clean name for initials: remove content in brackets/parentheses AND any non-alphanumeric chars at start
      final cleanName = entry.name.replaceAll(RegExp(r'[\(\[].*?[\)\]]'), '').replaceAll(RegExp(r'^[^a-zA-Z0-9]+'), '').trim();
      final words = cleanName.split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
      String initials = 'TV';
      if (words.length >= 2) {
        // Take first letter of first two words, ensuring they are letters/numbers
        String first = words[0].isNotEmpty ? words[0][0] : '';
        String second = words[1].isNotEmpty ? words[1][0] : '';
        initials = first + second;
      } else if (words.isNotEmpty) {
        initials = words[0].length >= 2 ? words[0].substring(0, 2) : words[0];
      }
      initials = initials.toUpperCase();

      channels.add(Channel(
        id: 'dyn-${DateTime.now().microsecondsSinceEpoch}-${channels.length}',
        name: entry.name,
        number: channels.length + 1,
        category: category,
        language: lang.isNotEmpty ? lang : 'English',
        country: country.isNotEmpty ? country : 'IN',
        logo: entry.logo,
        tvgId: entry.tvgId,
        tvgName: entry.name,
        description: '',
        streamUrl: entry.url,
        alternativeUrls: [entry.url],
        color: '#${(entry.name.hashCode & 0xFFFFFF).toRadixString(16).padLeft(6, '0')}',
        initials: initials,
        isDynamic: true,
      ));
      addedCount++;
    }

    return addedCount;
  }

  String _detectCategory(M3uEntry entry, String playlistType) {
    final name = entry.name.toLowerCase();
    final cat = entry.category.toLowerCase();

    if (playlistType == 'music' || cat.contains('music') || name.contains('music')) return 'music';
    if (playlistType == 'movies' || cat.contains('movie') || name.contains('movie')) return 'movies';
    if (playlistType == 'sports' || cat.contains('sport') || name.contains('sport')) return 'sports';
    if (playlistType == 'business' || cat.contains('business') || name.contains('business')) return 'business';

    if (playlistType == 'movies') return 'movies';
    if (playlistType == 'music') return 'music';
    if (playlistType == 'sports') return 'sports';
    if (playlistType == 'business') return 'business';

    final lang = _detectLanguage(entry.name, entry.category);
    if (lang == 'Hindi') return 'hindi-news';
    if (lang == 'English') {
      return (entry.country.isNotEmpty && entry.country != 'IN') ? 'international' : 'english-news';
    }
    return 'regional';
  }

  String _detectLanguage(String name, String category) {
    final n = name.toLowerCase();
    final c = category.toLowerCase();
    if (c.contains('hindi') || n.contains('hindi') || n.contains('bharat')) return 'Hindi';
    if (c.contains('tamil') || n.contains('tamil')) return 'Tamil';
    if (c.contains('telugu') || n.contains('telugu')) return 'Telugu';
    if (c.contains('bengali') || n.contains('bangla')) return 'Bengali';
    if (c.contains('kannada') || n.contains('kannada')) return 'Kannada';
    if (c.contains('malayalam') || n.contains('malayalam')) return 'Malayalam';
    if (c.contains('marathi') || n.contains('marathi')) return 'Marathi';
    if (c.contains('gujarati') || n.contains('gujarati')) return 'Gujarati';
    if (c.contains('punjabi') || n.contains('punjabi')) return 'Punjabi';
    return 'English';
  }

  void _reindex() {
    for (int i = 0; i < channels.length; i++) {
      channels[i].number = i + 1;
    }
  }

  /// Get channels filtered by category
  List<Channel> getByCategory(String categoryId) {
    if (categoryId == 'all') return channels.where((c) => c.hasStream).toList();
    return channels.where((c) => c.category == categoryId && c.hasStream).toList();
  }

  /// Get channels with streams
  List<Channel> get availableChannels => channels.where((c) => c.hasStream).toList();

  /// Find channel by ID
  Channel? findById(String id) {
    try {
      return channels.firstWhere((c) => c.id == id);
    } catch (_) {
      return null;
    }
  }

  /// Find channel by number
  Channel? findByNumber(int number) {
    try {
      return channels.firstWhere((c) => c.number == number && c.hasStream);
    } catch (_) {
      return null;
    }
  }

  /// Search channels
  List<Channel> search(String query) {
    final q = query.toLowerCase();
    return channels.where((c) {
      return c.hasStream &&
          (c.name.toLowerCase().contains(q) ||
           c.description.toLowerCase().contains(q) ||
           c.language.toLowerCase().contains(q) ||
           c.number.toString().contains(q));
    }).toList();
  }

  // -----------------------------------------------------------------------
  // Predefined channels (30 channels)
  // -----------------------------------------------------------------------
  static final List<Channel> _predefinedChannels = [
    // Hindi News (1-8)
    Channel(id: 'aaj-tak', name: 'Aaj Tak', number: 1, category: 'hindi-news', language: 'Hindi', country: 'IN', tvgId: 'AajTak.in', tvgName: 'Aaj Tak', description: 'Leading Hindi news channel', color: '#e53935', initials: 'AT'),
    Channel(id: 'ndtv-india', name: 'NDTV India', number: 2, category: 'hindi-news', language: 'Hindi', country: 'IN', tvgId: 'NDTVIndia.in', tvgName: 'NDTV India', description: 'Hindi news from NDTV', color: '#e8232a', initials: 'NI'),
    Channel(id: 'abp-news', name: 'ABP News', number: 3, category: 'hindi-news', language: 'Hindi', country: 'IN', tvgId: 'ABPNews.in', tvgName: 'ABP News', description: 'Popular Hindi news', color: '#ed1c24', initials: 'ABP'),
    Channel(id: 'zee-news', name: 'Zee News', number: 4, category: 'hindi-news', language: 'Hindi', country: 'IN', tvgId: 'ZeeNews.in', tvgName: 'Zee News', description: 'Zee Media group news', color: '#d32027', initials: 'ZN'),
    Channel(id: 'india-tv', name: 'India TV', number: 5, category: 'hindi-news', language: 'Hindi', country: 'IN', tvgId: 'IndiaTV.in', tvgName: 'India TV', description: 'Investigative reporting', color: '#1a4b8c', initials: 'IT'),
    Channel(id: 'republic-bharat', name: 'Republic Bharat', number: 6, category: 'hindi-news', language: 'Hindi', country: 'IN', tvgId: 'RepublicBharat.in', tvgName: 'Republic Bharat', description: 'Republic Media Hindi', color: '#1a237e', initials: 'RB'),
    Channel(id: 'news18-india', name: 'News18 India', number: 7, category: 'hindi-news', language: 'Hindi', country: 'IN', tvgId: 'News18India.in', tvgName: 'News18 India', description: 'Network18 Hindi news', color: '#cf2e2e', initials: 'N18'),
    Channel(id: 'tv9-bharatvarsh', name: 'TV9 Bharatvarsh', number: 8, category: 'hindi-news', language: 'Hindi', country: 'IN', tvgId: 'TV9Bharatvarsh.in', tvgName: 'TV9 Bharatvarsh', description: 'TV9 Network Hindi', color: '#ff6600', initials: 'TV9'),
    // English News (9-15)
    Channel(id: 'ndtv-24x7', name: 'NDTV 24x7', number: 9, category: 'english-news', language: 'English', country: 'IN', tvgId: 'NDTV24x7.in', tvgName: 'NDTV 24x7', description: 'Premier English news', color: '#e8232a', initials: 'ND'),
    Channel(id: 'republic-tv', name: 'Republic TV', number: 10, category: 'english-news', language: 'English', country: 'IN', tvgId: 'RepublicTV.in', tvgName: 'Republic TV', description: 'Debate-driven news', color: '#1a237e', initials: 'RT'),
    Channel(id: 'india-today', name: 'India Today', number: 11, category: 'english-news', language: 'English', country: 'IN', tvgId: 'IndiaToday.in', tvgName: 'India Today', description: 'India Today Group', color: '#e21c22', initials: 'IDT'),
    Channel(id: 'times-now', name: 'Times Now', number: 12, category: 'english-news', language: 'English', country: 'IN', tvgId: 'TimesNow.in', tvgName: 'Times Now', description: 'Times Network news', color: '#1a3e72', initials: 'TN'),
    Channel(id: 'wion', name: 'WION', number: 13, category: 'english-news', language: 'English', country: 'IN', tvgId: 'WION.in', tvgName: 'WION', description: 'World Is One News', color: '#0a1f44', initials: 'W'),
    Channel(id: 'cnn-news18', name: 'CNN-News18', number: 14, category: 'english-news', language: 'English', country: 'IN', tvgId: 'CNNNews18.in', tvgName: 'CNN-News18', description: 'CNN partner India', color: '#cc0000', initials: 'CN'),
    Channel(id: 'mirror-now', name: 'Mirror Now', number: 15, category: 'english-news', language: 'English', country: 'IN', tvgId: 'MirrorNow.in', tvgName: 'Mirror Now', description: 'Civic journalism', color: '#009fe3', initials: 'MN'),
    // Regional (16-21)
    Channel(id: 'sun-news', name: 'Sun News', number: 16, category: 'regional', language: 'Tamil', country: 'IN', tvgId: 'SunNews.in', tvgName: 'Sun News', description: 'Tamil news', color: '#f7941d', initials: 'SN'),
    Channel(id: 'tv9-telugu', name: 'TV9 Telugu', number: 17, category: 'regional', language: 'Telugu', country: 'IN', tvgId: 'TV9Telugu.in', tvgName: 'TV9 Telugu', description: 'Telugu news', color: '#ff6600', initials: 'T9'),
    Channel(id: 'abp-ananda', name: 'ABP Ananda', number: 18, category: 'regional', language: 'Bengali', country: 'IN', tvgId: 'ABPAnanda.in', tvgName: 'ABP Ananda', description: 'Bengali news', color: '#ed1c24', initials: 'AA'),
    Channel(id: 'asianet-news', name: 'Asianet News', number: 19, category: 'regional', language: 'Malayalam', country: 'IN', tvgId: 'AsianetNews.in', tvgName: 'Asianet News', description: 'Malayalam news', color: '#1a75bc', initials: 'AN'),
    Channel(id: 'tv9-kannada', name: 'TV9 Kannada', number: 20, category: 'regional', language: 'Kannada', country: 'IN', tvgId: 'TV9Kannada.in', tvgName: 'TV9 Kannada', description: 'Kannada news', color: '#ff6600', initials: 'K9'),
    Channel(id: 'news18-rajasthan', name: 'News18 Rajasthan', number: 21, category: 'regional', language: 'Hindi', country: 'IN', tvgId: 'News18Rajasthan.in', tvgName: 'News18 Rajasthan', description: 'Rajasthan news', color: '#cf2e2e', initials: 'NR'),
    // International (22-27)
    Channel(id: 'al-jazeera', name: 'Al Jazeera English', number: 22, category: 'international', language: 'English', country: 'QA', tvgId: 'AlJazeeraEnglish.qa', tvgName: 'Al Jazeera English', description: 'International news', color: '#d2982b', initials: 'AJ'),
    Channel(id: 'france-24', name: 'France 24 English', number: 23, category: 'international', language: 'English', country: 'FR', tvgId: 'France24English.fr', tvgName: 'France 24', description: 'French international news', color: '#00a2e6', initials: 'F24'),
    Channel(id: 'dw-news', name: 'DW News', number: 24, category: 'international', language: 'English', country: 'DE', tvgId: 'DWEnglish.de', tvgName: 'DW News', description: 'German broadcaster', color: '#0055a0', initials: 'DW'),
    Channel(id: 'euronews', name: 'Euronews', number: 25, category: 'international', language: 'English', country: 'FR', tvgId: 'EuronewsEnglish.fr', tvgName: 'Euronews', description: 'Pan-European news', color: '#003d7d', initials: 'EN'),
    Channel(id: 'nhk-world', name: 'NHK World Japan', number: 26, category: 'international', language: 'English', country: 'JP', tvgId: 'NHKWorldJapan.jp', tvgName: 'NHK World', description: 'Japanese broadcasting', color: '#333333', initials: 'NHK'),
    Channel(id: 'trt-world', name: 'TRT World', number: 27, category: 'international', language: 'English', country: 'TR', tvgId: 'TRTWorld.tr', tvgName: 'TRT World', description: 'Turkish international', color: '#e30a17', initials: 'TRT'),
    // Business (28-30)
    Channel(id: 'cnbc-tv18', name: 'CNBC TV18', number: 28, category: 'business', language: 'English', country: 'IN', tvgId: 'CNBCTV18.in', tvgName: 'CNBC TV18', description: 'Business news', color: '#003f72', initials: 'CB'),
    Channel(id: 'et-now', name: 'ET Now', number: 29, category: 'business', language: 'English', country: 'IN', tvgId: 'ETNow.in', tvgName: 'ET Now', description: 'Economic Times news', color: '#0070c0', initials: 'ET'),
    Channel(id: 'ndtv-profit', name: 'NDTV Profit', number: 30, category: 'business', language: 'English', country: 'IN', tvgId: 'NDTVProfit.in', tvgName: 'NDTV Profit', description: 'NDTV business', color: '#e8232a', initials: 'NP'),
  ];
}
