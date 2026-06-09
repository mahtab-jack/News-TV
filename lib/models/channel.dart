/// Channel data model for News TV
class Channel {
  final String id;
  final String name;
  int number;
  final String category;
  final String language;
  final String country;
  String logo;
  final String tvgId;
  final String tvgName;
  final String description;
  String? streamUrl;
  List<String> alternativeUrls;
  final String color;
  final String initials;
  final bool isDynamic;
  String region;

  Channel({
    required this.id,
    required this.name,
    required this.number,
    required this.category,
    required this.language,
    required this.country,
    this.logo = '',
    this.tvgId = '',
    this.tvgName = '',
    this.description = '',
    this.streamUrl,
    this.alternativeUrls = const [],
    required this.color,
    required this.initials,
    this.isDynamic = false,
    this.region = 'National',
  });

  Map<String, dynamic> toJson() => {
    'id': id,
    'name': name,
    'number': number,
    'category': category,
    'language': language,
    'country': country,
    'logo': logo,
    'streamUrl': streamUrl,
    'initials': initials,
  };

  bool get hasStream => streamUrl != null && streamUrl!.isNotEmpty;
}

/// TV playback state sent to the remote
class TvState {
  final String? channelId;
  final String? channelName;
  final int? channelNumber;
  final String? channelLogo;
  final bool playing;
  final bool muted;
  final int volume;
  final List<String> favorites;

  TvState({
    this.channelId,
    this.channelName,
    this.channelNumber,
    this.channelLogo,
    this.playing = false,
    this.muted = false,
    this.volume = 80,
    this.favorites = const [],
  });

  Map<String, dynamic> toJson() => {
    'channelId': channelId,
    'channelName': channelName,
    'channelNumber': channelNumber,
    'channelLogo': channelLogo,
    'playing': playing,
    'muted': muted,
    'volume': volume,
    'favorites': favorites,
  };
}
