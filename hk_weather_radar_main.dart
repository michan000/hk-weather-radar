// ============================================================================
// 香港及亞太區天氣雷達 App (Weather & Radar + Live Radar 專業控制版)
// ============================================================================
//
// 📦 1. 所需套件 (`pubspec.yaml` 或由 GitHub Actions `build.yml` 自動安裝)：
//   flutter pub add http flutter_map latlong2 fl_chart shared_preferences
//
// 🌟 2. 本次更新與錯誤修復重點：
//   - 修復 `type 'String' is not a subtype of type 'List<dynamic>?' in type cast` 錯誤：
//     香港天文台 HKO Open Data API (`rhrread`) 在沒有生效警告或無紫外線數據時，
//     `warningMessage` 與 `uvindex` 等欄位會回傳空字串 `""` 而非 `List` 或 `Map`。
//     現已全面改為型別安全解析 (`_asList` / `_asMap` / `_asDouble` / `_asInt`)，
//     並為所有 API 加入獨立容錯保護，確保任何單一欄位異常都不會中斷畫面！
//   - 修正底圖 (Basemap) 開不了的問題：內建 8 款底圖切換（含免 Key 的香港政府 CSDI
//     官方中英文街道地圖、OSM 標準圖、Esri 全球衛星圖、Carto 直連深淺色圖，以及支援
//     輸入 API Key 的 MapTiler / Mapbox / Stadia）。
//   - 完整設定與 API Key 控制中心 (支援本機自動記憶 SharedPreferences)。
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const HKWeatherRadarApp());
}

// ----------------------------------------------------------------------------
// JSON 型別安全轉換輔助函式 (徹底防止 HKO API 回傳 "" 空字串時發生 Type Cast Error)
// ----------------------------------------------------------------------------

Map<String, dynamic> _asMap(dynamic value) {
  if (value is Map<String, dynamic>) return value;
  if (value is Map) return Map<String, dynamic>.from(value);
  return <String, dynamic>{};
}

List<dynamic> _asList(dynamic value) {
  if (value is List) return value;
  return <dynamic>[];
}

List<String> _asStringList(dynamic value) {
  if (value is List) {
    return value
        .map((e) => e?.toString().trim() ?? '')
        .where((s) => s.isNotEmpty)
        .toList();
  }
  if (value is String && value.trim().isNotEmpty) {
    return [value.trim()];
  }
  return <String>[];
}

double? _asDouble(dynamic value) {
  if (value is num) return value.toDouble();
  if (value is String) return double.tryParse(value);
  return null;
}

int? _asInt(dynamic value) {
  if (value is num) return value.toInt();
  if (value is String) return int.tryParse(value);
  return null;
}

class HKWeatherRadarApp extends StatelessWidget {
  const HKWeatherRadarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HK & APAC Weather Radar Pro',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0B1120),
        cardColor: const Color(0xFF1E293B),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFF818CF8),
          surface: Color(0xFF1E293B),
        ),
      ),
      home: const WeatherRadarHomeScreen(),
    );
  }
}

// ----------------------------------------------------------------------------
// 1. 枚舉與預設城市座標設定 (香港分區 + 亞太主要城市)
// ----------------------------------------------------------------------------

enum BasemapProvider {
  osmStandard('OSM 標準街道底圖 (免 Key 最穩定)', false),
  hkCsdi('香港政府官方地圖 CSDI (免 Key 香港首選)', false),
  esriSatellite('Esri 全球衛星實景底圖 (免 Key 觀雲雨)', false),
  cartoDark('CartoDB 深色高對比底圖 (免 Key 直連)', false),
  cartoLight('CartoDB 淺色簡潔底圖 (免 Key 直連)', false),
  mapTilerDark('MapTiler 高清深色向量圖 (需 MapTiler Key)', true),
  mapboxDark('Mapbox 專業深色底圖 (需 Mapbox Key)', true),
  stadiaDark('Stadia Alidade 深色底圖 (需 Stadia Key)', true);

  final String label;
  final bool requiresKey;
  const BasemapProvider(this.label, this.requiresKey);
}

enum RadarLayerType {
  rainViewerRadar('全球動態降雨雷達 (RainViewer 免 Key)', false),
  rainViewerInfrared('全球紅外線衛星雲圖 (RainViewer 免 Key)', false),
  rainbowAi('Rainbow.ai 高清 AI 臨近預報雷達 (需 Key)', true),
  owmPrecipitation('OpenWeatherMap 全球降水圖層 (需 OWM Key)', true),
  owmClouds('OpenWeatherMap 雲量分佈圖層 (需 OWM Key)', true),
  owmTemp('OpenWeatherMap 氣溫熱力圖層 (需 OWM Key)', true),
  owmWind('OpenWeatherMap 風速分佈圖層 (需 OWM Key)', true);

  final String label;
  final bool requiresKey;
  const RadarLayerType(this.label, this.requiresKey);
}

enum ForecastModelSource {
  hkoPlusBest('香港天文台 HKO + 亞太最佳模型 (推薦)', 'best_match'),
  jma('日本氣象廳模型 (JMA MSM/GSM - 東亞極準)', 'jma_seamless'),
  ecmwf('歐洲中期天氣預報中心 (ECMWF IFS)', 'ecmwf_ifs04'),
  cma('中國氣象局全球模型 (CMA GRAPES)', 'cma_grapes_global'),
  gfs('美國國家氣象局模型 (NOAA GFS)', 'gfs_seamless'),
  openWeatherMap('OpenWeatherMap 官方預報 API (需 OWM Key)', 'owm');

  final String label;
  final String apiParam;
  const ForecastModelSource(this.label, this.apiParam);
}

class PresetLocation {
  final String name;
  final LatLng coords;
  final bool isHongKong;

  const PresetLocation({
    required this.name,
    required this.coords,
    required this.isHongKong,
  });
}

const List<PresetLocation> kPresetLocations = [
  PresetLocation(name: '香港 (尖沙咀天文台)', coords: LatLng(22.3027, 114.1772), isHongKong: true),
  PresetLocation(name: '香港 (中環 / 港島)', coords: LatLng(22.2819, 114.1581), isHongKong: true),
  PresetLocation(name: '香港 (沙田 / 新界東)', coords: LatLng(22.3816, 114.1885), isHongKong: true),
  PresetLocation(name: '香港 (元朗 / 新界西)', coords: LatLng(22.4445, 114.0222), isHongKong: true),
  PresetLocation(name: '香港 (赤鱲角機場)', coords: LatLng(22.3080, 113.9185), isHongKong: true),
  PresetLocation(name: '澳門', coords: LatLng(22.1987, 113.5439), isHongKong: false),
  PresetLocation(name: '台北', coords: LatLng(25.0330, 121.5654), isHongKong: false),
  PresetLocation(name: '東京', coords: LatLng(35.6762, 139.6503), isHongKong: false),
  PresetLocation(name: '大阪', coords: LatLng(34.6937, 135.5023), isHongKong: false),
  PresetLocation(name: '首爾', coords: LatLng(37.5665, 126.9780), isHongKong: false),
  PresetLocation(name: '新加坡', coords: LatLng(1.3521, 103.8198), isHongKong: false),
  PresetLocation(name: '曼谷', coords: LatLng(13.7563, 100.5018), isHongKong: false),
];

// 香港主要自動氣象站參考座標 (用於在地圖上顯示實時分區氣溫氣泡)
const Map<String, LatLng> kHkoStationCoords = {
  '香港天文台': LatLng(22.3019, 114.1742),
  '京士柏': LatLng(22.3119, 114.1728),
  '黃竹坑': LatLng(22.2478, 114.1736),
  '打鼓嶺': LatLng(22.5286, 114.1567),
  '流浮山': LatLng(22.4689, 113.9836),
  '大埔': LatLng(22.4461, 114.1789),
  '沙田': LatLng(22.4025, 114.2100),
  '屯門': LatLng(22.3858, 113.9642),
  '將軍澳': LatLng(22.3158, 114.2556),
  '西貢': LatLng(22.3756, 114.2744),
  '長洲': LatLng(22.2011, 114.0267),
  '赤鱲角': LatLng(22.3094, 113.9219),
  '青衣': LatLng(22.3442, 114.1100),
  '石崗': LatLng(22.4361, 114.0847),
  '荃灣可觀': LatLng(22.3836, 114.1078),
  '荃灣城門谷': LatLng(22.3756, 114.1267),
  '香港公園': LatLng(22.2783, 114.1622),
  '筲箕灣': LatLng(22.2817, 114.2361),
  '九龍城': LatLng(22.3350, 114.1847),
  '跑馬地': LatLng(22.2706, 114.1836),
  '黃大仙': LatLng(22.3397, 114.1953),
  '赤柱': LatLng(22.2142, 114.2186),
  '觀塘': LatLng(22.3186, 114.2247),
  '深水埗': LatLng(22.3358, 114.1369),
  '啟德跑道公園': LatLng(22.3047, 114.2139),
  '元朗公園': LatLng(22.4408, 114.0189),
  '大美督': LatLng(22.4753, 114.2375),
};

// ----------------------------------------------------------------------------
// 2. 使用者設定與 API Key 狀態管理 (AppSettings)
// ----------------------------------------------------------------------------

class AppSettings {
  BasemapProvider basemap;
  RadarLayerType radarLayer;
  ForecastModelSource forecastSource;

  // 自訂 API Keys
  String mapTilerApiKey;
  String mapboxApiKey;
  String stadiaApiKey;
  String openWeatherApiKey;
  String rainbowAiApiKey;
  String tomorrowIoApiKey;

  // 雷達與介面控制參數
  double radarOpacity;
  int radarColorScheme; // RainViewer: 1=Original, 2=Universal Blue, 4=TITAN, 6=NEXRAD, 8=Dark Sky
  int playbackSpeedMs;
  bool smoothRadar;
  bool showHkoStationMarkers;
  bool useFahrenheit;
  String windSpeedUnit; // 'km/h', 'm/s', 'kn'

  AppSettings({
    this.basemap = BasemapProvider.osmStandard,
    this.radarLayer = RadarLayerType.rainViewerRadar,
    this.forecastSource = ForecastModelSource.hkoPlusBest,
    this.mapTilerApiKey = '',
    this.mapboxApiKey = '',
    this.stadiaApiKey = '',
    this.openWeatherApiKey = '',
    this.rainbowAiApiKey = '',
    this.tomorrowIoApiKey = '',
    this.radarOpacity = 0.75,
    this.radarColorScheme = 2,
    this.playbackSpeedMs = 600,
    this.smoothRadar = true,
    this.showHkoStationMarkers = true,
    this.useFahrenheit = false,
    this.windSpeedUnit = 'km/h',
  });

  Future<void> saveToPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setInt('basemap', basemap.index);
    await prefs.setInt('radarLayer', radarLayer.index);
    await prefs.setInt('forecastSource', forecastSource.index);
    await prefs.setString('mapTilerApiKey', mapTilerApiKey.trim());
    await prefs.setString('mapboxApiKey', mapboxApiKey.trim());
    await prefs.setString('stadiaApiKey', stadiaApiKey.trim());
    await prefs.setString('openWeatherApiKey', openWeatherApiKey.trim());
    await prefs.setString('rainbowAiApiKey', rainbowAiApiKey.trim());
    await prefs.setString('tomorrowIoApiKey', tomorrowIoApiKey.trim());
    await prefs.setDouble('radarOpacity', radarOpacity);
    await prefs.setInt('radarColorScheme', radarColorScheme);
    await prefs.setInt('playbackSpeedMs', playbackSpeedMs);
    await prefs.setBool('smoothRadar', smoothRadar);
    await prefs.setBool('showHkoStationMarkers', showHkoStationMarkers);
    await prefs.setBool('useFahrenheit', useFahrenheit);
    await prefs.setString('windSpeedUnit', windSpeedUnit);
  }

  static Future<AppSettings> loadFromPrefs() async {
    final prefs = await SharedPreferences.getInstance();
    final bIdx = prefs.getInt('basemap') ?? 0;
    final rIdx = prefs.getInt('radarLayer') ?? 0;
    final fIdx = prefs.getInt('forecastSource') ?? 0;

    return AppSettings(
      basemap: BasemapProvider.values[bIdx.clamp(0, BasemapProvider.values.length - 1)],
      radarLayer: RadarLayerType.values[rIdx.clamp(0, RadarLayerType.values.length - 1)],
      forecastSource: ForecastModelSource.values[fIdx.clamp(0, ForecastModelSource.values.length - 1)],
      mapTilerApiKey: prefs.getString('mapTilerApiKey') ?? '',
      mapboxApiKey: prefs.getString('mapboxApiKey') ?? '',
      stadiaApiKey: prefs.getString('stadiaApiKey') ?? '',
      openWeatherApiKey: prefs.getString('openWeatherApiKey') ?? '',
      rainbowAiApiKey: prefs.getString('rainbowAiApiKey') ?? '',
      tomorrowIoApiKey: prefs.getString('tomorrowIoApiKey') ?? '',
      radarOpacity: prefs.getDouble('radarOpacity') ?? 0.75,
      radarColorScheme: prefs.getInt('radarColorScheme') ?? 2,
      playbackSpeedMs: prefs.getInt('playbackSpeedMs') ?? 600,
      smoothRadar: prefs.getBool('smoothRadar') ?? true,
      showHkoStationMarkers: prefs.getBool('showHkoStationMarkers') ?? true,
      useFahrenheit: prefs.getBool('useFahrenheit') ?? false,
      windSpeedUnit: prefs.getString('windSpeedUnit') ?? 'km/h',
    );
  }

  /// 取得穩定底圖 URL Template (不含會導致新版 flutter_map 報錯的 {r} 佔位符)
  String getBasemapUrlTemplate() {
    switch (basemap) {
      case BasemapProvider.osmStandard:
        return 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
      case BasemapProvider.hkCsdi:
        // 香港政府空間數據共享平台 (CSDI) 官方向量轉柵格中文街道地圖 (免 Key)
        return 'https://mapapi.geodata.gov.hk/gs/api/v1.0.0/xyz/basemap/WGS84/{z}/{x}/{y}.png';
      case BasemapProvider.esriSatellite:
        // Esri World Imagery 全球衛星實景圖 (免 Key)
        return 'https://server.arcgisonline.com/ArcGIS/rest/services/World_Imagery/MapServer/tile/{z}/{y}/{x}';
      case BasemapProvider.cartoDark:
        return 'https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png';
      case BasemapProvider.cartoLight:
        return 'https://a.basemaps.cartocdn.com/light_all/{z}/{x}/{y}.png';
      case BasemapProvider.mapTilerDark:
        if (mapTilerApiKey.isEmpty) {
          return 'https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png';
        }
        return 'https://api.maptiler.com/maps/dataviz-dark/{z}/{x}/{y}.png?key=$mapTilerApiKey';
      case BasemapProvider.mapboxDark:
        if (mapboxApiKey.isEmpty) {
          return 'https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png';
        }
        return 'https://api.mapbox.com/styles/v1/mapbox/dark-v11/tiles/256/{z}/{x}/{y}?access_token=$mapboxApiKey';
      case BasemapProvider.stadiaDark:
        if (stadiaApiKey.isEmpty) {
          return 'https://a.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}.png';
        }
        return 'https://tiles.stadiamaps.com/tiles/alidade_smooth_dark/{z}/{x}/{y}.png?api_key=$stadiaApiKey';
    }
  }

  /// 檢查目前選擇的底圖是否缺少必填的 API Key
  bool get isCurrentBasemapMissingKey {
    if (basemap == BasemapProvider.mapTilerDark && mapTilerApiKey.isEmpty) return true;
    if (basemap == BasemapProvider.mapboxDark && mapboxApiKey.isEmpty) return true;
    if (basemap == BasemapProvider.stadiaDark && stadiaApiKey.isEmpty) return true;
    return false;
  }

  /// 檢查目前選擇的氣象圖層是否缺少必填的 API Key
  bool get isCurrentRadarMissingKey {
    if (radarLayer == RadarLayerType.rainbowAi && rainbowAiApiKey.isEmpty) return true;
    if ((radarLayer == RadarLayerType.owmPrecipitation ||
            radarLayer == RadarLayerType.owmClouds ||
            radarLayer == RadarLayerType.owmTemp ||
            radarLayer == RadarLayerType.owmWind) &&
        openWeatherApiKey.isEmpty) {
      return true;
    }
    return false;
  }

  String formatTemp(num? celsius) {
    if (celsius == null) return '--';
    if (useFahrenheit) {
      final f = celsius * 9 / 5 + 32;
      return '${f.toStringAsFixed(1)}°F';
    }
    return '${celsius.toStringAsFixed(1)}°C';
  }

  String formatWind(num? kmh) {
    if (kmh == null) return '--';
    if (windSpeedUnit == 'm/s') {
      return '${(kmh / 3.6).toStringAsFixed(1)} m/s';
    } else if (windSpeedUnit == 'kn') {
      return '${(kmh / 1.852).toStringAsFixed(1)} 節';
    }
    return '${kmh.toStringAsFixed(0)} km/h';
  }
}

// ----------------------------------------------------------------------------
// 3. 資料結構模型 (Data Models)
// ----------------------------------------------------------------------------

class RadarFrame {
  final int time;
  final String path;
  final bool isForecast;

  RadarFrame({
    required this.time,
    required this.path,
    this.isForecast = false,
  });

  String get formattedTime {
    final dt = DateTime.fromMillisecondsSinceEpoch(time * 1000).toLocal();
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

class HkoStationTemp {
  final String place;
  final double temp;
  final LatLng coords;

  HkoStationTemp({
    required this.place,
    required this.temp,
    required this.coords,
  });
}

class CurrentMetrics {
  final double? temp;
  final double? apparentTemp;
  final int? humidity;
  final double? windSpeedKmh;
  final int? windDirectionDeg;
  final double? pressureHpa;
  final double? uvIndex;
  final double? precipMm;
  final String summaryText;

  CurrentMetrics({
    this.temp,
    this.apparentTemp,
    this.humidity,
    this.windSpeedKmh,
    this.windDirectionDeg,
    this.pressureHpa,
    this.uvIndex,
    this.precipMm,
    this.summaryText = '',
  });
}

class HourlyPoint {
  final String timeLabel;
  final double temp;
  final int precipProb;
  final double windSpeed;

  HourlyPoint({
    required this.timeLabel,
    required this.temp,
    required this.precipProb,
    required this.windSpeed,
  });
}

class DailyForecastItem {
  final String date;
  final String week;
  final double minTemp;
  final double maxTemp;
  final String forecastWeather;
  final String psr;

  DailyForecastItem({
    required this.date,
    required this.week,
    required this.minTemp,
    required this.maxTemp,
    required this.forecastWeather,
    required this.psr,
  });
}

// ----------------------------------------------------------------------------
// 4. 多來源氣象數據倉庫 (WeatherRepository)
// ----------------------------------------------------------------------------

class WeatherRepository {
  /// 1. 取得 RainViewer 雷達與紅外線衛星雲圖時間軸
  Future<Map<String, dynamic>> fetchRainViewerFrames() async {
    final uri = Uri.parse('https://api.rainviewer.com/public/weather-maps.json');
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw Exception('無法載入 RainViewer 雷達索引 (${response.statusCode})');
    }
    final data = _asMap(jsonDecode(response.body));
    final String host = data['host']?.toString() ?? 'https://tilecache.rainviewer.com';

    final List<RadarFrame> radarFrames = [];
    final radar = _asMap(data['radar']);
    for (final raw in _asList(radar['past'])) {
      final item = _asMap(raw);
      final time = _asInt(item['time']);
      final path = item['path']?.toString() ?? '';
      if (time != null && path.isNotEmpty) {
        radarFrames.add(RadarFrame(time: time, path: path, isForecast: false));
      }
    }
    for (final raw in _asList(radar['nowcast'])) {
      final item = _asMap(raw);
      final time = _asInt(item['time']);
      final path = item['path']?.toString() ?? '';
      if (time != null && path.isNotEmpty) {
        radarFrames.add(RadarFrame(time: time, path: path, isForecast: true));
      }
    }

    final List<RadarFrame> satelliteFrames = [];
    final satellite = _asMap(data['satellite']);
    for (final raw in _asList(satellite['infrared'])) {
      final item = _asMap(raw);
      final time = _asInt(item['time']);
      final path = item['path']?.toString() ?? '';
      if (time != null && path.isNotEmpty) {
        satelliteFrames.add(RadarFrame(time: time, path: path, isForecast: false));
      }
    }

    return {
      'host': host,
      'radarFrames': radarFrames,
      'satelliteFrames': satelliteFrames,
    };
  }

  /// 2. 取得香港天文台 (HKO) 實時分區天氣、警告與 18 區氣象站溫度
  Future<Map<String, dynamic>> fetchHkoCurrentWeather() async {
    final uri = Uri.parse(
      'https://data.weather.gov.hk/weatherAPI/opendata/weather.php?dataType=rhrread&lang=tc',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw Exception('無法載入香港天文台實時天氣');
    }
    return _asMap(jsonDecode(response.body));
  }

  /// 3. 取得香港天文台 (HKO) 9 天預報
  Future<List<DailyForecastItem>> fetchHko9DayForecast() async {
    final uri = Uri.parse(
      'https://data.weather.gov.hk/weatherAPI/opendata/weather.php?dataType=fnd&lang=tc',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw Exception('無法載入香港天文台 9 天預報');
    }
    final data = _asMap(jsonDecode(response.body));
    final list = _asList(data['weatherForecast']);
    return list.map((raw) {
      final item = _asMap(raw);
      final rawDate = item['forecastDate']?.toString() ?? '';
      final formattedDate = rawDate.length == 8
          ? '${rawDate.substring(4, 6)}/${rawDate.substring(6, 8)}'
          : rawDate;
      final minMap = _asMap(item['forecastMintemp']);
      final maxMap = _asMap(item['forecastMaxtemp']);
      return DailyForecastItem(
        date: formattedDate,
        week: item['week']?.toString() ?? '',
        minTemp: _asDouble(minMap['value']) ?? 0.0,
        maxTemp: _asDouble(maxMap['value']) ?? 0.0,
        forecastWeather: item['forecastWeather']?.toString() ?? '',
        psr: item['PSR']?.toString() ?? '中',
      );
    }).toList();
  }

  /// 4. 取得 Open-Meteo 亞太區預報 (支援切換 JMA、ECMWF、CMA、GFS 模型)
  Future<Map<String, dynamic>> fetchOpenMeteoData(
    LatLng location,
    ForecastModelSource modelSource,
  ) async {
    String modelQuery = '';
    if (modelSource != ForecastModelSource.hkoPlusBest &&
        modelSource != ForecastModelSource.openWeatherMap) {
      modelQuery = '&models=${modelSource.apiParam}';
    }

    final uri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=${location.latitude}&longitude=${location.longitude}'
      '&current=temperature_2m,relative_humidity_2m,apparent_temperature,precipitation,surface_pressure,wind_speed_10m,wind_direction_10m'
      '&hourly=temperature_2m,precipitation_probability,wind_speed_10m,uv_index'
      '&daily=temperature_2m_max,temperature_2m_min,precipitation_probability_max'
      '&forecast_days=9&timezone=auto$modelQuery',
    );
    final response = await http.get(uri).timeout(const Duration(seconds: 12));
    if (response.statusCode != 200) {
      throw Exception('Open-Meteo 預報載入失敗 (${response.statusCode})');
    }
    return _asMap(jsonDecode(response.body));
  }

  /// 5. 若使用者輸入了 OpenWeatherMap API Key 並指定使用 OWM 預報
  Future<Map<String, dynamic>?> fetchOpenWeatherCurrent(
    LatLng location,
    String apiKey,
  ) async {
    if (apiKey.isEmpty) return null;
    try {
      final uri = Uri.parse(
        'https://api.openweathermap.org/data/2.5/weather'
        '?lat=${location.latitude}&lon=${location.longitude}'
        '&appid=$apiKey&units=metric&lang=zh_tw',
      );
      final response = await http.get(uri).timeout(const Duration(seconds: 10));
      if (response.statusCode != 200) return null;
      return _asMap(jsonDecode(response.body));
    } catch (_) {
      return null;
    }
  }
}

// ----------------------------------------------------------------------------
// 5. 主畫面 (WeatherRadarHomeScreen)
// ----------------------------------------------------------------------------

class WeatherRadarHomeScreen extends StatefulWidget {
  const WeatherRadarHomeScreen({super.key});

  @override
  State<WeatherRadarHomeScreen> createState() => _WeatherRadarHomeScreenState();
}

class _WeatherRadarHomeScreenState extends State<WeatherRadarHomeScreen> {
  final WeatherRepository _repo = WeatherRepository();
  final MapController _mapController = MapController();

  AppSettings _settings = AppSettings();
  PresetLocation _selectedLocation = kPresetLocations.first;
  bool _isFullScreenMap = false;

  // 雷達狀態
  String _radarHost = 'https://tilecache.rainviewer.com';
  List<RadarFrame> _radarFrames = [];
  List<RadarFrame> _satelliteFrames = [];
  int _currentFrameIndex = 0;
  bool _isPlaying = false;
  Timer? _playbackTimer;

  // 氣象資料狀態
  bool _isLoading = true;
  String? _errorMessage;
  CurrentMetrics _metrics = CurrentMetrics();
  List<String> _hkWarnings = [];
  List<HkoStationTemp> _stationTemps = [];
  List<HourlyPoint> _hourlyPoints = [];
  List<DailyForecastItem> _dailyForecasts = [];

  @override
  void initState() {
    super.initState();
    _initSettingsAndLoad();
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    super.dispose();
  }

  Future<void> _initSettingsAndLoad() async {
    final loaded = await AppSettings.loadFromPrefs();
    setState(() {
      _settings = loaded;
    });
    await _loadAllWeatherData();
  }

  List<RadarFrame> get _activeFrames {
    if (_settings.radarLayer == RadarLayerType.rainViewerInfrared) {
      return _satelliteFrames;
    }
    return _radarFrames;
  }

  Future<void> _loadAllWeatherData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      // 各項資料來源均加上獨立安全保護，單一來源異常也不會影響整體 App 運作
      final results = await Future.wait([
        _repoSafeRainViewer(),
        _repoSafeOpenMeteo(),
        _repoSafeHkoCurrent(),
        _repoSafeHko9Day(),
      ]);

      final rvData = _asMap(results[0]);
      final omData = _asMap(results[1]);
      final hkoCurrent = results[2] as Map<String, dynamic>?;
      final hko9Day = results[3] as List<DailyForecastItem>?;

      // 1. 型別安全解析香港 18 區氣象站溫度、濕度、UV 與警告 (修正 HKO 回傳空字串 "" 的問題)
      final List<HkoStationTemp> stations = [];
      double? hkoMainTemp;
      int? hkoMainHumidity;
      double? hkoUv;
      List<String> warnings = [];

      if (hkoCurrent != null) {
        final tempSection = _asMap(hkoCurrent['temperature']);
        final tempList = _asList(tempSection['data']);
        for (final rawItem in tempList) {
          final item = _asMap(rawItem);
          final place = item['place']?.toString() ?? '';
          final val = _asDouble(item['value']);
          if (val != null && kHkoStationCoords.containsKey(place)) {
            stations.add(HkoStationTemp(
              place: place,
              temp: val,
              coords: kHkoStationCoords[place]!,
            ));
          }
          if (place == '香港天文台' && val != null) {
            hkoMainTemp = val;
          }
        }

        final rhSection = _asMap(hkoCurrent['humidity']);
        final rhList = _asList(rhSection['data']);
        if (rhList.isNotEmpty) {
          final firstRh = _asMap(rhList.first);
          hkoMainHumidity = _asInt(firstRh['value']);
        }

        // HKO 的 uvindex 在夜間或無數據時會回傳空字串 ""，使用 _asMap + _asList 可安全略過
        final uvSection = _asMap(hkoCurrent['uvindex']);
        final uvList = _asList(uvSection['data']);
        if (uvList.isNotEmpty) {
          final firstUv = _asMap(uvList.first);
          hkoUv = _asDouble(firstUv['value']);
        }

        // HKO 的 warningMessage 在無警告生效時會回傳空字串 ""，使用 _asStringList 可安全處理
        warnings = _asStringList(hkoCurrent['warningMessage']);
      }

      // 2. 型別安全解析 Open-Meteo 當前與逐小時數據
      final current = _asMap(omData['current']);
      final hourly = _asMap(omData['hourly']);
      final times = _asList(hourly['time']);
      final hTemps = _asList(hourly['temperature_2m']);
      final hProbs = _asList(hourly['precipitation_probability']);
      final hWinds = _asList(hourly['wind_speed_10m']);
      final hUvs = _asList(hourly['uv_index']);

      final List<HourlyPoint> hourlyList = [];
      final int count = times.length < 24 ? times.length : 24;
      for (int i = 0; i < count; i++) {
        final rawTime = times[i]?.toString() ?? '';
        final hhmm = rawTime.contains('T') ? rawTime.split('T').last : rawTime;
        hourlyList.add(HourlyPoint(
          timeLabel: hhmm,
          temp: (hTemps.length > i ? _asDouble(hTemps[i]) : null) ?? 0.0,
          precipProb: (hProbs.length > i ? _asInt(hProbs[i]) : null) ?? 0,
          windSpeed: (hWinds.length > i ? _asDouble(hWinds[i]) : null) ?? 0.0,
        ));
      }

      // 3. 若選用 OpenWeatherMap API 且填有 Key，覆蓋當前指標
      double? finalTemp = _selectedLocation.isHongKong && hkoMainTemp != null
          ? hkoMainTemp
          : _asDouble(current['temperature_2m']);
      int? finalHumidity = _selectedLocation.isHongKong && hkoMainHumidity != null
          ? hkoMainHumidity
          : _asInt(current['relative_humidity_2m']);
      String summary = _selectedLocation.isHongKong
          ? '香港天文台 HKO + ${_settings.forecastSource.label}'
          : _settings.forecastSource.label;

      if (_settings.forecastSource == ForecastModelSource.openWeatherMap &&
          _settings.openWeatherApiKey.isNotEmpty) {
        final owm = await _repo.fetchOpenWeatherCurrent(
          _selectedLocation.coords,
          _settings.openWeatherApiKey,
        );
        if (owm != null) {
          final mainMap = _asMap(owm['main']);
          finalTemp = _asDouble(mainMap['temp']) ?? finalTemp;
          finalHumidity = _asInt(mainMap['humidity']) ?? finalHumidity;
          summary = 'OpenWeatherMap 實時 API';
        }
      }

      final metrics = CurrentMetrics(
        temp: finalTemp,
        apparentTemp: _asDouble(current['apparent_temperature']) ?? finalTemp,
        humidity: finalHumidity,
        windSpeedKmh: _asDouble(current['wind_speed_10m']),
        windDirectionDeg: _asInt(current['wind_direction_10m']),
        pressureHpa: _asDouble(current['surface_pressure']),
        uvIndex: hkoUv ?? (hUvs.isNotEmpty ? _asDouble(hUvs.first) : 0.0),
        precipMm: _asDouble(current['precipitation']) ?? 0.0,
        summaryText: summary,
      );

      // 4. 多日預報：若在香港則優先顯示香港天文台 9 天預報，否則使用 Open-Meteo 多日預報
      List<DailyForecastItem> dailyList = [];
      if (_selectedLocation.isHongKong && hko9Day != null && hko9Day.isNotEmpty) {
        dailyList = hko9Day;
      } else {
        final daily = _asMap(omData['daily']);
        final dDates = _asList(daily['time']);
        final dMax = _asList(daily['temperature_2m_max']);
        final dMin = _asList(daily['temperature_2m_min']);
        final dProb = _asList(daily['precipitation_probability_max']);
        for (int i = 0; i < dDates.length; i++) {
          final raw = dDates[i]?.toString() ?? '';
          final shortDate =
              raw.length >= 10 ? raw.substring(5).replaceAll('-', '/') : raw;
          final prob = (dProb.length > i ? _asInt(dProb[i]) : null) ?? 0;
          dailyList.add(DailyForecastItem(
            date: shortDate,
            week: 'Day ${i + 1}',
            minTemp: (dMin.length > i ? _asDouble(dMin[i]) : null) ?? 0.0,
            maxTemp: (dMax.length > i ? _asDouble(dMax[i]) : null) ?? 0.0,
            forecastWeather: prob >= 60
                ? '有陣雨或雷雨'
                : (prob >= 30 ? '局部多雲有雨' : '大致天晴至多雲'),
            psr: '$prob%',
          ));
        }
      }

      final rFrames = (rvData['radarFrames'] as List<RadarFrame>?) ?? <RadarFrame>[];
      final sFrames =
          (rvData['satelliteFrames'] as List<RadarFrame>?) ?? <RadarFrame>[];

      setState(() {
        _radarHost = rvData['host']?.toString() ?? 'https://tilecache.rainviewer.com';
        _radarFrames = rFrames;
        _satelliteFrames = sFrames;
        final active = _activeFrames;
        _currentFrameIndex = active.isNotEmpty ? active.length - 1 : 0;
        _metrics = metrics;
        _hkWarnings = warnings;
        _stationTemps = stations;
        _hourlyPoints = hourlyList;
        _dailyForecasts = dailyList;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  Future<Map<String, dynamic>> _repoSafeRainViewer() async {
    try {
      return await _repo.fetchRainViewerFrames();
    } catch (_) {
      return {
        'host': 'https://tilecache.rainviewer.com',
        'radarFrames': <RadarFrame>[],
        'satelliteFrames': <RadarFrame>[],
      };
    }
  }

  Future<Map<String, dynamic>> _repoSafeOpenMeteo() async {
    try {
      return await _repo.fetchOpenMeteoData(
        _selectedLocation.coords,
        _settings.forecastSource,
      );
    } catch (_) {
      // 若指定模型暫時不可用，自動退回預設最佳模型
      try {
        return await _repo.fetchOpenMeteoData(
          _selectedLocation.coords,
          ForecastModelSource.hkoPlusBest,
        );
      } catch (_) {
        return <String, dynamic>{};
      }
    }
  }

  Future<Map<String, dynamic>?> _repoSafeHkoCurrent() async {
    try {
      return await _repo.fetchHkoCurrentWeather();
    } catch (_) {
      return null;
    }
  }

  Future<List<DailyForecastItem>?> _repoSafeHko9Day() async {
    try {
      return await _repo.fetchHko9DayForecast();
    } catch (_) {
      return null;
    }
  }

  void _restartPlaybackTimerIfNeeded() {
    _playbackTimer?.cancel();
    if (_isPlaying && _activeFrames.isNotEmpty) {
      _playbackTimer = Timer.periodic(
        Duration(milliseconds: _settings.playbackSpeedMs),
        (_) {
          if (!mounted || _activeFrames.isEmpty) return;
          setState(() {
            _currentFrameIndex = (_currentFrameIndex + 1) % _activeFrames.length;
          });
        },
      );
    }
  }

  void _toggleRadarPlayback() {
    if (_activeFrames.isEmpty) return;
    setState(() {
      _isPlaying = !_isPlaying;
    });
    _restartPlaybackTimerIfNeeded();
  }

  /// 組裝目前選擇的動態氣象/雷達圖層 URL Template
  String? _buildActiveOverlayUrlTemplate(RadarFrame? frame) {
    final smoothFlag = _settings.smoothRadar ? 1 : 0;
    switch (_settings.radarLayer) {
      case RadarLayerType.rainViewerRadar:
        if (frame == null) return null;
        return '$_radarHost${frame.path}/256/{z}/{x}/{y}/${_settings.radarColorScheme}/${smoothFlag}_1.png';
      case RadarLayerType.rainViewerInfrared:
        if (frame == null) return null;
        return '$_radarHost${frame.path}/256/{z}/{x}/{y}/0/0_0.png';
      case RadarLayerType.rainbowAi:
        if (_settings.rainbowAiApiKey.isEmpty) return null;
        final ts = frame?.time ?? (DateTime.now().millisecondsSinceEpoch ~/ 1000);
        return 'https://api.rainbow.ai/tiles/v1/precip/$ts/{z}/{x}/{y}.png?token=${_settings.rainbowAiApiKey}';
      case RadarLayerType.owmPrecipitation:
        if (_settings.openWeatherApiKey.isEmpty) return null;
        return 'https://tile.openweathermap.org/map/precipitation_new/{z}/{x}/{y}.png?appid=${_settings.openWeatherApiKey}';
      case RadarLayerType.owmClouds:
        if (_settings.openWeatherApiKey.isEmpty) return null;
        return 'https://tile.openweathermap.org/map/clouds_new/{z}/{x}/{y}.png?appid=${_settings.openWeatherApiKey}';
      case RadarLayerType.owmTemp:
        if (_settings.openWeatherApiKey.isEmpty) return null;
        return 'https://tile.openweathermap.org/map/temp_new/{z}/{x}/{y}.png?appid=${_settings.openWeatherApiKey}';
      case RadarLayerType.owmWind:
        if (_settings.openWeatherApiKey.isEmpty) return null;
        return 'https://tile.openweathermap.org/map/wind_new/{z}/{x}/{y}.png?appid=${_settings.openWeatherApiKey}';
    }
  }

  /// 打開「完整設定、API Key 與資料來源控制中心」
  void _openSettingsSheet() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF0F172A),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
      ),
      builder: (context) {
        return SettingsControlSheet(
          initialSettings: _settings,
          onSave: (updated) async {
            await updated.saveToPrefs();
            setState(() {
              _settings = updated;
              final active = _activeFrames;
              if (_currentFrameIndex >= active.length) {
                _currentFrameIndex = active.isNotEmpty ? active.length - 1 : 0;
              }
            });
            _restartPlaybackTimerIfNeeded();
            _loadAllWeatherData();
          },
        );
      },
    );
  }

  /// 快速切換底圖選單
  void _openQuickBasemapPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  '選擇地圖底圖 (Basemap)',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: BasemapProvider.values.map((provider) {
                    final isSelected = _settings.basemap == provider;
                    return ListTile(
                      leading: Icon(
                        provider.requiresKey ? Icons.vpn_key : Icons.public,
                        color: isSelected ? const Color(0xFF38BDF8) : Colors.white70,
                      ),
                      title: Text(provider.label),
                      trailing: isSelected
                          ? const Icon(Icons.check_circle, color: Color(0xFF38BDF8))
                          : null,
                      onTap: () async {
                        Navigator.pop(context);
                        setState(() {
                          _settings.basemap = provider;
                        });
                        await _settings.saveToPrefs();
                        if (_settings.isCurrentBasemapMissingKey) {
                          _openSettingsSheet();
                        }
                      },
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// 快速切換雷達與氣象圖層選單
  void _openQuickRadarLayerPicker() {
    showModalBottomSheet(
      context: context,
      backgroundColor: const Color(0xFF1E293B),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
      ),
      builder: (context) {
        return SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.all(16.0),
                child: Text(
                  '切換氣象雷達 / 衛星 / 熱力圖層',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                ),
              ),
              Flexible(
                child: ListView(
                  shrinkWrap: true,
                  children: RadarLayerType.values.map((layer) {
                    final isSelected = _settings.radarLayer == layer;
                    return ListTile(
                      leading: Icon(
                        layer.requiresKey ? Icons.vpn_key : Icons.layers,
                        color: isSelected ? const Color(0xFF38BDF8) : Colors.white70,
                      ),
                      title: Text(layer.label),
                      trailing: isSelected
                          ? const Icon(Icons.check_circle, color: Color(0xFF38BDF8))
                          : null,
                      onTap: () async {
                        Navigator.pop(context);
                        setState(() {
                          _settings.radarLayer = layer;
                          final active = _activeFrames;
                          _currentFrameIndex = active.isNotEmpty ? active.length - 1 : 0;
                        });
                        await _settings.saveToPrefs();
                        if (_settings.isCurrentRadarMissingKey) {
                          _openSettingsSheet();
                        }
                      },
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0B1120),
        elevation: 0,
        titleSpacing: 12,
        title: Row(
          children: [
            const Icon(Icons.radar, color: Color(0xFF38BDF8)),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    _selectedLocation.name,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                    overflow: TextOverflow.ellipsis,
                  ),
                  Text(
                    _metrics.summaryText,
                    style: const TextStyle(fontSize: 11, color: Colors.white60),
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (_metrics.temp != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: const Color(0xFF38BDF8).withOpacity(0.4)),
                ),
                child: Text(
                  _settings.formatTemp(_metrics.temp),
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF38BDF8),
                  ),
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAllWeatherData,
            tooltip: '重新整理',
          ),
          IconButton(
            icon: const Icon(Icons.tune, color: Color(0xFF38BDF8)),
            onPressed: _openSettingsSheet,
            tooltip: '設定、API Key 與資料來源',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text('載入失敗：$_errorMessage'),
                        const SizedBox(height: 12),
                        ElevatedButton(
                          onPressed: _loadAllWeatherData,
                          child: const Text('重試'),
                        ),
                      ],
                    ),
                  ),
                )
              : _isFullScreenMap
                  ? _buildInteractiveRadarCard(isFullScreen: true)
                  : RefreshIndicator(
                      onRefresh: _loadAllWeatherData,
                      child: ListView(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                        children: [
                          _buildLocationQuickBar(),
                          const SizedBox(height: 8),
                          if (_hkWarnings.isNotEmpty) _buildWarningBanner(),
                          if (_settings.isCurrentBasemapMissingKey ||
                              _settings.isCurrentRadarMissingKey)
                            _buildMissingApiKeyBanner(),
                          _buildInteractiveRadarCard(isFullScreen: false),
                          const SizedBox(height: 14),
                          _buildLiveMetricsGrid(),
                          const SizedBox(height: 14),
                          _buildHourlyForecastCard(),
                          const SizedBox(height: 14),
                          _buildNineDayForecastCard(),
                          const SizedBox(height: 24),
                        ],
                      ),
                    ),
    );
  }

  /// 頂部香港分區與亞太城市快速切換列
  Widget _buildLocationQuickBar() {
    return SizedBox(
      height: 38,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        itemCount: kPresetLocations.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, index) {
          final loc = kPresetLocations[index];
          final selected = loc.name == _selectedLocation.name;
          return ChoiceChip(
            label: Text(loc.name, style: const TextStyle(fontSize: 12)),
            selected: selected,
            selectedColor: const Color(0xFF38BDF8).withOpacity(0.25),
            onSelected: (_) {
              setState(() {
                _selectedLocation = loc;
              });
              _mapController.move(loc.coords, loc.isHongKong ? 10.2 : 7.5);
              _loadAllWeatherData();
            },
          );
        },
      ),
    );
  }

  /// 香港天文台實時警告橫幅
  Widget _buildWarningBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.amber.withOpacity(0.15),
        border: Border.all(color: Colors.amberAccent),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(Icons.warning_amber_rounded, color: Colors.amberAccent),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              _hkWarnings.join('\n'),
              style: const TextStyle(fontSize: 12, color: Colors.amberAccent),
            ),
          ),
        ],
      ),
    );
  }

  /// 缺少 API Key 時的友善提示橫幅
  Widget _buildMissingApiKeyBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.blueAccent.withOpacity(0.18),
        border: Border.all(color: const Color(0xFF38BDF8)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          const Icon(Icons.vpn_key, color: Color(0xFF38BDF8), size: 20),
          const SizedBox(width: 10),
          const Expanded(
            child: Text(
              '你目前選用的底圖或進階氣象圖層需要 API Key，目前已自動使用免費備援底圖。',
              style: TextStyle(fontSize: 12),
            ),
          ),
          TextButton(
            onPressed: _openSettingsSheet,
            child: const Text('輸入 Key'),
          ),
        ],
      ),
    );
  }

  /// Weather & Radar 風格互動雷達地圖卡片 + 懸浮控制面板 + 時間軸 + 色階圖例
  Widget _buildInteractiveRadarCard({required bool isFullScreen}) {
    final frames = _activeFrames;
    final currentFrame = frames.isNotEmpty
        ? frames[_currentFrameIndex.clamp(0, frames.length - 1)]
        : null;
    final overlayUrl = _buildActiveOverlayUrlTemplate(currentFrame);
    final basemapUrl = _settings.getBasemapUrlTemplate();

    final mapHeight = isFullScreen
        ? MediaQuery.of(context).size.height - 210
        : 370.0;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: mapHeight,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: MapOptions(
                    initialCenter: _selectedLocation.coords,
                    initialZoom: 9.5,
                    minZoom: 3.0,
                    maxZoom: 16.0,
                  ),
                  children: [
                    // 1. 穩定底圖圖層 (支援免 Key 與自訂 Key)
                    TileLayer(
                      key: ValueKey<String>(basemapUrl),
                      urlTemplate: basemapUrl,
                      userAgentPackageName: 'hk.weather.radar.pro',
                    ),
                    // 2. 動態氣象雷達 / 衛星 / OWM 圖層
                    if (overlayUrl != null)
                      Opacity(
                        opacity: _settings.radarOpacity,
                        child: TileLayer(
                          key: ValueKey<String>(overlayUrl),
                          urlTemplate: overlayUrl,
                          userAgentPackageName: 'hk.weather.radar.pro',
                        ),
                      ),
                    // 3. 香港天文台 18 區實時氣象站溫度標記
                    if (_settings.showHkoStationMarkers && _stationTemps.isNotEmpty)
                      MarkerLayer(
                        markers: _stationTemps.map((st) {
                          return Marker(
                            point: st.coords,
                            width: 68,
                            height: 36,
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 5,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(0xFF0F172A).withOpacity(0.85),
                                borderRadius: BorderRadius.circular(8),
                                border: Border.all(
                                  color: const Color(0xFF38BDF8),
                                  width: 1,
                                ),
                              ),
                              child: Column(
                                mainAxisAlignment: MainAxisAlignment.center,
                                children: [
                                  Text(
                                    st.place,
                                    style: const TextStyle(
                                      fontSize: 8,
                                      color: Colors.white70,
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    '${st.temp.toStringAsFixed(1)}°',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    // 4. 目前選中定位大頭針
                    MarkerLayer(
                      markers: [
                        Marker(
                          point: _selectedLocation.coords,
                          width: 40,
                          height: 40,
                          child: const Icon(
                            Icons.my_location,
                            color: Colors.amberAccent,
                            size: 28,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),

                // 左上角：目前啟用的底圖與雷達狀態標籤
                Positioned(
                  top: 10,
                  left: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withOpacity(0.85),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          currentFrame?.isForecast == true
                              ? Icons.auto_awesome
                              : Icons.sensors,
                          size: 14,
                          color: currentFrame?.isForecast == true
                              ? Colors.amberAccent
                              : const Color(0xFF38BDF8),
                        ),
                        const SizedBox(width: 6),
                        Text(
                          currentFrame?.isForecast == true ? 'AI 預報雷達' : '實時觀測圖層',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // 右上角：Weather & Radar 風格懸浮控制按鈕群
                Positioned(
                  top: 10,
                  right: 10,
                  child: Column(
                    children: [
                      _buildMapControlButton(
                        icon: isFullScreen ? Icons.fullscreen_exit : Icons.fullscreen,
                        tooltip: isFullScreen ? '退出全螢幕' : '全螢幕雷達地圖',
                        onTap: () {
                          setState(() {
                            _isFullScreenMap = !_isFullScreenMap;
                          });
                        },
                      ),
                      const SizedBox(height: 8),
                      _buildMapControlButton(
                        icon: Icons.map_outlined,
                        tooltip: '切換底圖 (Basemap)',
                        onTap: _openQuickBasemapPicker,
                      ),
                      const SizedBox(height: 8),
                      _buildMapControlButton(
                        icon: Icons.layers_outlined,
                        tooltip: '切換氣象雷達圖層',
                        onTap: _openQuickRadarLayerPicker,
                      ),
                      const SizedBox(height: 8),
                      _buildMapControlButton(
                        icon: _settings.showHkoStationMarkers
                            ? Icons.thermostat
                            : Icons.thermostat_outlined,
                        tooltip: '顯示/隱藏香港各區氣溫標記',
                        active: _settings.showHkoStationMarkers,
                        onTap: () async {
                          setState(() {
                            _settings.showHkoStationMarkers =
                                !_settings.showHkoStationMarkers;
                          });
                          await _settings.saveToPrefs();
                        },
                      ),
                      const SizedBox(height: 8),
                      _buildMapControlButton(
                        icon: Icons.gps_fixed,
                        tooltip: '重新置中目前城市',
                        onTap: () {
                          _mapController.move(
                            _selectedLocation.coords,
                            _selectedLocation.isHongKong ? 10.2 : 7.5,
                          );
                        },
                      ),
                    ],
                  ),
                ),

                // 左下角：降雨強度色階圖例 (Color Legend)
                Positioned(
                  bottom: 8,
                  left: 10,
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: const Color(0xFF0F172A).withOpacity(0.85),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('小雨 ', style: TextStyle(fontSize: 10)),
                        Container(
                          width: 80,
                          height: 8,
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(4),
                            gradient: const LinearGradient(
                              colors: [
                                Color(0xFF38BDF8),
                                Color(0xFF22C55E),
                                Color(0xFFEAB308),
                                Color(0xFFEF4444),
                                Color(0xFFA855F7),
                              ],
                            ),
                          ),
                        ),
                        const Text(' 暴雨', style: TextStyle(fontSize: 10)),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),

          // 底部時間軸與透明度/設定快速控制列
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: const Color(0xFF1E293B),
            child: Column(
              children: [
                Row(
                  children: [
                    IconButton(
                      icon: Icon(
                        _isPlaying
                            ? Icons.pause_circle_filled
                            : Icons.play_circle_fill,
                        color: const Color(0xFF38BDF8),
                        size: 34,
                      ),
                      onPressed: _toggleRadarPlayback,
                    ),
                    if (currentFrame != null)
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            currentFrame.formattedTime,
                            style: const TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 14,
                            ),
                          ),
                          Text(
                            currentFrame.isForecast ? '預報' : '過去觀測',
                            style: TextStyle(
                              fontSize: 10,
                              color: currentFrame.isForecast
                                  ? Colors.amberAccent
                                  : Colors.white60,
                            ),
                          ),
                        ],
                      ),
                    Expanded(
                      child: frames.isEmpty
                          ? const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 12),
                              child: Text(
                                '固定圖層模式 (無時間軸)',
                                style: TextStyle(fontSize: 12, color: Colors.white54),
                              ),
                            )
                          : Slider(
                              value: _currentFrameIndex
                                  .clamp(0, frames.length - 1)
                                  .toDouble(),
                              min: 0,
                              max: (frames.length - 1).toDouble(),
                              divisions: frames.length > 1 ? frames.length - 1 : 1,
                              onChanged: (value) {
                                setState(() {
                                  _isPlaying = false;
                                  _playbackTimer?.cancel();
                                  _currentFrameIndex = value.round();
                                });
                              },
                            ),
                    ),
                    TextButton.icon(
                      onPressed: _openSettingsSheet,
                      icon: const Icon(Icons.settings, size: 16),
                      label: const Text('設定', style: TextStyle(fontSize: 12)),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMapControlButton({
    required IconData icon,
    required String tooltip,
    required VoidCallback onTap,
    bool active = false,
  }) {
    return Material(
      color: active
          ? const Color(0xFF38BDF8)
          : const Color(0xFF0F172A).withOpacity(0.85),
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Tooltip(
          message: tooltip,
          child: Padding(
            padding: const EdgeInsets.all(8.0),
            child: Icon(
              icon,
              size: 20,
              color: active ? const Color(0xFF0F172A) : Colors.white,
            ),
          ),
        ),
      ),
    );
  }

  /// 6 格即時專業環境指標網格 (參考 Live Radar App 設計)
  Widget _buildLiveMetricsGrid() {
    final items = [
      {
        'icon': Icons.thermostat_auto,
        'label': '體感溫度',
        'value': _settings.formatTemp(_metrics.apparentTemp ?? _metrics.temp),
      },
      {
        'icon': Icons.water_drop_outlined,
        'label': '相對濕度',
        'value': _metrics.humidity != null ? '${_metrics.humidity}%' : '--',
      },
      {
        'icon': Icons.air,
        'label': '風速與風向',
        'value':
            '${_settings.formatWind(_metrics.windSpeedKmh)} (${_metrics.windDirectionDeg ?? 0}°)',
      },
      {
        'icon': Icons.wb_sunny_outlined,
        'label': '紫外線指數 (UV)',
        'value': _metrics.uvIndex != null
            ? _metrics.uvIndex!.toStringAsFixed(1)
            : '--',
      },
      {
        'icon': Icons.speed,
        'label': '海平面氣壓',
        'value': _metrics.pressureHpa != null
            ? '${_metrics.pressureHpa!.toStringAsFixed(0)} hPa'
            : '--',
      },
      {
        'icon': Icons.umbrella_outlined,
        'label': '實時降水量',
        'value': _metrics.precipMm != null
            ? '${_metrics.precipMm!.toStringAsFixed(1)} mm'
            : '0.0 mm',
      },
    ];

    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      itemCount: items.length,
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.55,
      ),
      itemBuilder: (context, index) {
        final item = items[index];
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: const Color(0xFF1E293B),
            borderRadius: BorderRadius.circular(14),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Row(
                children: [
                  Icon(
                    item['icon'] as IconData,
                    size: 15,
                    color: const Color(0xFF38BDF8),
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      item['label'] as String,
                      style: const TextStyle(fontSize: 11, color: Colors.white60),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Text(
                item['value'] as String,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ],
          ),
        );
      },
    );
  }

  /// 逐小時預報卡片
  Widget _buildHourlyForecastCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Text(
                  '未來 24 小時逐時預報',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
                ),
                Text(
                  _settings.forecastSource.label.split(' ').first,
                  style: const TextStyle(fontSize: 11, color: Color(0xFF38BDF8)),
                ),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 108,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: _hourlyPoints.length,
                separatorBuilder: (_, __) => const SizedBox(width: 16),
                itemBuilder: (context, index) {
                  final pt = _hourlyPoints[index];
                  return Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        pt.timeLabel,
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _settings.formatTemp(pt.temp),
                        style: const TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(
                            Icons.water_drop,
                            size: 11,
                            color: Color(0xFF38BDF8),
                          ),
                          Text(
                            '${pt.precipProb}%',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF38BDF8),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _settings.formatWind(pt.windSpeed),
                        style: const TextStyle(fontSize: 10, color: Colors.white54),
                      ),
                    ],
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 9 天天氣預報清單
  Widget _buildNineDayForecastCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              _selectedLocation.isHongKong ? '香港天文台 9 天天氣預報' : '未來 9 天天氣趨勢',
              style: const TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ..._dailyForecasts.map((day) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 90,
                      child: Text(
                        '${day.date} (${day.week})',
                        style: const TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 12,
                        ),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0B1120),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '降雨: ${day.psr}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF38BDF8),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        day.forecastWeather,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(fontSize: 12, color: Colors.white70),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${_settings.formatTemp(day.minTemp)} / ${_settings.formatTemp(day.maxTemp)}',
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              );
            }),
          ],
        ),
      ),
    );
  }
}

// ----------------------------------------------------------------------------
// 6. 完整設定、底圖 API Key 與資料來源控制面板 (SettingsControlSheet)
// ----------------------------------------------------------------------------

class SettingsControlSheet extends StatefulWidget {
  final AppSettings initialSettings;
  final ValueChanged<AppSettings> onSave;

  const SettingsControlSheet({
    super.key,
    required this.initialSettings,
    required this.onSave,
  });

  @override
  State<SettingsControlSheet> createState() => _SettingsControlSheetState();
}

class _SettingsControlSheetState extends State<SettingsControlSheet> {
  late BasemapProvider _basemap;
  late RadarLayerType _radarLayer;
  late ForecastModelSource _forecastSource;

  late TextEditingController _mapTilerKeyCtrl;
  late TextEditingController _mapboxKeyCtrl;
  late TextEditingController _stadiaKeyCtrl;
  late TextEditingController _owmKeyCtrl;
  late TextEditingController _rainbowKeyCtrl;
  late TextEditingController _tomorrowKeyCtrl;

  late double _radarOpacity;
  late int _radarColorScheme;
  late int _playbackSpeedMs;
  late bool _smoothRadar;
  late bool _showHkoStations;
  late bool _useFahrenheit;
  late String _windSpeedUnit;

  @override
  void initState() {
    super.initState();
    final s = widget.initialSettings;
    _basemap = s.basemap;
    _radarLayer = s.radarLayer;
    _forecastSource = s.forecastSource;

    _mapTilerKeyCtrl = TextEditingController(text: s.mapTilerApiKey);
    _mapboxKeyCtrl = TextEditingController(text: s.mapboxApiKey);
    _stadiaKeyCtrl = TextEditingController(text: s.stadiaApiKey);
    _owmKeyCtrl = TextEditingController(text: s.openWeatherApiKey);
    _rainbowKeyCtrl = TextEditingController(text: s.rainbowAiApiKey);
    _tomorrowKeyCtrl = TextEditingController(text: s.tomorrowIoApiKey);

    _radarOpacity = s.radarOpacity;
    _radarColorScheme = s.radarColorScheme;
    _playbackSpeedMs = s.playbackSpeedMs;
    _smoothRadar = s.smoothRadar;
    _showHkoStations = s.showHkoStationMarkers;
    _useFahrenheit = s.useFahrenheit;
    _windSpeedUnit = s.windSpeedUnit;
  }

  @override
  void dispose() {
    _mapTilerKeyCtrl.dispose();
    _mapboxKeyCtrl.dispose();
    _stadiaKeyCtrl.dispose();
    _owmKeyCtrl.dispose();
    _rainbowKeyCtrl.dispose();
    _tomorrowKeyCtrl.dispose();
    super.dispose();
  }

  void _handleSave() {
    final updated = AppSettings(
      basemap: _basemap,
      radarLayer: _radarLayer,
      forecastSource: _forecastSource,
      mapTilerApiKey: _mapTilerKeyCtrl.text.trim(),
      mapboxApiKey: _mapboxKeyCtrl.text.trim(),
      stadiaApiKey: _stadiaKeyCtrl.text.trim(),
      openWeatherApiKey: _owmKeyCtrl.text.trim(),
      rainbowAiApiKey: _rainbowKeyCtrl.text.trim(),
      tomorrowIoApiKey: _tomorrowKeyCtrl.text.trim(),
      radarOpacity: _radarOpacity,
      radarColorScheme: _radarColorScheme,
      playbackSpeedMs: _playbackSpeedMs,
      smoothRadar: _smoothRadar,
      showHkoStationMarkers: _showHkoStations,
      useFahrenheit: _useFahrenheit,
      windSpeedUnit: _windSpeedUnit,
    );
    widget.onSave(updated);
    Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: bottomInset),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.88,
        minChildSize: 0.5,
        maxChildSize: 0.95,
        builder: (context, scrollController) {
          return Column(
            children: [
              // 頂部標題與儲存按鈕
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                decoration: const BoxDecoration(
                  color: Color(0xFF1E293B),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.tune, color: Color(0xFF38BDF8)),
                    const SizedBox(width: 8),
                    const Expanded(
                      child: Text(
                        '控制中心：資料來源、底圖與 API Key',
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                    ),
                    ElevatedButton.icon(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF38BDF8),
                        foregroundColor: const Color(0xFF0F172A),
                      ),
                      onPressed: _handleSave,
                      icon: const Icon(Icons.save, size: 18),
                      label: const Text(
                        '儲存並套用',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ),

              Expanded(
                child: ListView(
                  controller: scrollController,
                  padding: const EdgeInsets.all(16),
                  children: [
                    // 區塊 1：地圖底圖 (Basemap) 選擇與 API Key
                    _buildSectionTitle('1. 地圖底圖 (Basemap) 來源與 API Key'),
                    DropdownButtonFormField<BasemapProvider>(
                      value: _basemap,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '選擇地圖底圖 (免 Key 或自訂 Key)',
                        border: OutlineInputBorder(),
                      ),
                      items: BasemapProvider.values.map((b) {
                        return DropdownMenuItem(
                          value: b,
                          child: Text(b.label, style: const TextStyle(fontSize: 13)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) setState(() => _basemap = val);
                      },
                    ),
                    const SizedBox(height: 12),
                    _buildApiKeyField(
                      controller: _mapTilerKeyCtrl,
                      label: 'MapTiler API Key (選填，用於 MapTiler 高清深色底圖)',
                      hint: '貼上你的 MapTiler Key...',
                    ),
                    const SizedBox(height: 10),
                    _buildApiKeyField(
                      controller: _mapboxKeyCtrl,
                      label: 'Mapbox Access Token (選填，用於 Mapbox 專業底圖)',
                      hint: 'pk.eyJ1Ijoi...',
                    ),
                    const SizedBox(height: 10),
                    _buildApiKeyField(
                      controller: _stadiaKeyCtrl,
                      label: 'Stadia Maps API Key (選填，用於 Stadia 深色底圖)',
                      hint: '貼上你的 Stadia Key...',
                    ),

                    const Divider(height: 32),

                    // 區塊 2：氣象預報模型與雷達圖層來源
                    _buildSectionTitle('2. 亞太氣象預報模型與雷達圖層來源'),
                    DropdownButtonFormField<ForecastModelSource>(
                      value: _forecastSource,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '定點預報資料來源 / 數值模型',
                        border: OutlineInputBorder(),
                      ),
                      items: ForecastModelSource.values.map((f) {
                        return DropdownMenuItem(
                          value: f,
                          child: Text(f.label, style: const TextStyle(fontSize: 13)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) setState(() => _forecastSource = val);
                      },
                    ),
                    const SizedBox(height: 12),
                    DropdownButtonFormField<RadarLayerType>(
                      value: _radarLayer,
                      isExpanded: true,
                      decoration: const InputDecoration(
                        labelText: '地圖疊加氣象圖層 (雷達 / 衛星雲圖 / 氣溫 / 風速)',
                        border: OutlineInputBorder(),
                      ),
                      items: RadarLayerType.values.map((r) {
                        return DropdownMenuItem(
                          value: r,
                          child: Text(r.label, style: const TextStyle(fontSize: 13)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) setState(() => _radarLayer = val);
                      },
                    ),
                    const SizedBox(height: 12),
                    _buildApiKeyField(
                      controller: _owmKeyCtrl,
                      label: 'OpenWeatherMap API Key (選填，解鎖 OWM 降水/雲量/溫度/風場圖層)',
                      hint: '貼上 32 位元 OpenWeatherMap Key...',
                    ),
                    const SizedBox(height: 10),
                    _buildApiKeyField(
                      controller: _rainbowKeyCtrl,
                      label: 'Rainbow.ai API Token (選填，解鎖 4 小時高清 AI 雷達瓦片)',
                      hint: '貼上 Rainbow.ai Token...',
                    ),
                    const SizedBox(height: 10),
                    _buildApiKeyField(
                      controller: _tomorrowKeyCtrl,
                      label: 'Tomorrow.io API Key (選填，備用企業級氣象圖層)',
                      hint: '貼上 Tomorrow.io Key...',
                    ),

                    const Divider(height: 32),

                    // 區塊 3：雷達視覺效果與動畫控制
                    _buildSectionTitle('3. 雷達視覺效果、色階與播放控制'),
                    Row(
                      children: [
                        const SizedBox(width: 110, child: Text('雷達圖層透明度')),
                        Expanded(
                          child: Slider(
                            value: _radarOpacity,
                            min: 0.2,
                            max: 1.0,
                            divisions: 8,
                            label: '${(_radarOpacity * 100).round()}%',
                            onChanged: (val) => setState(() => _radarOpacity = val),
                          ),
                        ),
                        Text('${(_radarOpacity * 100).round()}%'),
                      ],
                    ),
                    Row(
                      children: [
                        const SizedBox(width: 110, child: Text('時間軸播放速度')),
                        Expanded(
                          child: Slider(
                            value: _playbackSpeedMs.toDouble(),
                            min: 250,
                            max: 1200,
                            divisions: 19,
                            label: '${_playbackSpeedMs}ms',
                            onChanged: (val) =>
                                setState(() => _playbackSpeedMs = val.round()),
                          ),
                        ),
                        Text('${_playbackSpeedMs}ms'),
                      ],
                    ),
                    const SizedBox(height: 8),
                    DropdownButtonFormField<int>(
                      value: _radarColorScheme,
                      decoration: const InputDecoration(
                        labelText: '雷達回波色階主題 (RainViewer 色盤)',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 1, child: Text('1 - 經典原色 (Original)')),
                        DropdownMenuItem(
                            value: 2, child: Text('2 - 環球藍紫漸層 (Universal Blue - 推薦)')),
                        DropdownMenuItem(value: 4, child: Text('4 - 高對比雷暴 (TITAN)')),
                        DropdownMenuItem(value: 6, child: Text('6 - 美式氣象雷達 (NEXRAD)')),
                        DropdownMenuItem(value: 8, child: Text('8 - 極簡深色 (Dark Sky)')),
                      ],
                      onChanged: (val) {
                        if (val != null) setState(() => _radarColorScheme = val);
                      },
                    ),
                    SwitchListTile(
                      title: const Text('平滑化雷達邊緣 (Smooth Rendering)'),
                      subtitle: const Text('開啟後雷達雨帶邊緣更柔和，關閉則顯示原始格點'),
                      value: _smoothRadar,
                      onChanged: (val) => setState(() => _smoothRadar = val),
                    ),
                    SwitchListTile(
                      title: const Text('在地圖上顯示香港 18 區氣象站實時溫度'),
                      subtitle: const Text('直接在地圖對應位置顯示天文台自動氣象站氣溫氣泡'),
                      value: _showHkoStations,
                      onChanged: (val) => setState(() => _showHkoStations = val),
                    ),

                    const Divider(height: 32),

                    // 區塊 4：顯示單位設定
                    _buildSectionTitle('4. 溫度與風速單位設定'),
                    SwitchListTile(
                      title: const Text('使用華氏溫度 (°F)'),
                      subtitle: const Text('預設為攝氏 (°C)'),
                      value: _useFahrenheit,
                      onChanged: (val) => setState(() => _useFahrenheit = val),
                    ),
                    DropdownButtonFormField<String>(
                      value: _windSpeedUnit,
                      decoration: const InputDecoration(
                        labelText: '風速單位',
                        border: OutlineInputBorder(),
                      ),
                      items: const [
                        DropdownMenuItem(value: 'km/h', child: Text('公里/小時 (km/h)')),
                        DropdownMenuItem(value: 'm/s', child: Text('米/秒 (m/s)')),
                        DropdownMenuItem(value: 'kn', child: Text('海里/節 (Knots)')),
                      ],
                      onChanged: (val) {
                        if (val != null) setState(() => _windSpeedUnit = val);
                      },
                    ),
                    const SizedBox(height: 30),
                  ],
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSectionTitle(String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Text(
        title,
        style: const TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.bold,
          color: Color(0xFF38BDF8),
        ),
      ),
    );
  }

  Widget _buildApiKeyField({
    required TextEditingController controller,
    required String label,
    required String hint,
  }) {
    return TextField(
      controller: controller,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        prefixIcon: const Icon(Icons.key, size: 18),
        suffixIcon: controller.text.isNotEmpty
            ? IconButton(
                icon: const Icon(Icons.clear, size: 18),
                onPressed: () => setState(() => controller.clear()),
              )
            : null,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
    );
  }
}