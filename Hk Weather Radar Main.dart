// ============================================================================
// 香港及亞太區天氣雷達 App (Weather & Radar 風格) — Flutter 核心啟動模版
// ============================================================================
//
// 📦 1. 請在專案的 `pubspec.yaml` 加入以下套件：
// dependencies:
//   flutter:
//     sdk: flutter
//   http: ^1.2.2
//   flutter_map: ^7.0.2
//   latlong2: ^0.9.1
//   fl_chart: ^0.69.0
//
// 🌐 2. 資料來源與 API 說明（全部免 API Key 即可測試）：
//   - 香港天文台開放數據 API (實時分區氣溫、警告、9天預報)：
//     https://www.hko.gov.hk/en/weatherAPI/doc/files/HKO_Open_Data_API_Documentation.pdf
//   - Open-Meteo API (融合日本氣象廳 JMA 與 ECMWF 亞太區逐小時預報)：
//     https://open-meteo.com/en/docs
//   - RainViewer / Rainbow.ai 格式之動態氣象雷達 XYZ 圖磚：
//     https://www.rainviewer.com/api/weather-maps-api.html
// ============================================================================

import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:http/http.dart' as http;
import 'package:latlong2/latlong.dart';

void main() {
  runApp(const HKWeatherRadarApp());
}

class HKWeatherRadarApp extends StatelessWidget {
  const HKWeatherRadarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'HK & APAC Weather Radar',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0F172A),
        cardColor: const Color(0xFF1E293B),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF38BDF8),
          secondary: Color(0xFF818CF8),
        ),
      ),
      home: const WeatherRadarHomeScreen(),
    );
  }
}

// ----------------------------------------------------------------------------
// 資料模型 (Data Models)
// ----------------------------------------------------------------------------

class RadarFrame {
  final int time;
  final String path;

  RadarFrame({required this.time, required this.path});

  String get formattedTime {
    final dt = DateTime.fromMillisecondsSinceEpoch(time * 1000).toLocal();
    final hh = dt.hour.toString().padLeft(2, '0');
    final mm = dt.minute.toString().padLeft(2, '0');
    return '$hh:$mm';
  }
}

class HourlyPoint {
  final String timeLabel;
  final double temp;
  final int precipProb;

  HourlyPoint({
    required this.timeLabel,
    required this.temp,
    required this.precipProb,
  });
}

class DailyForecastItem {
  final String date;
  final String week;
  final int minTemp;
  final int maxTemp;
  final String forecastWeather;
  final String psr; // 降雨概率等級 (例如：高、中、低)

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
// 雙核心氣象資料服務 (HKO 香港天文台 + Open-Meteo 亞太區 + 動態雷達圖磚)
// ----------------------------------------------------------------------------

class WeatherRepository {
  static const LatLng hkCenter = LatLng(22.3027, 114.1772); // 香港天文台總部座標

  /// 1. 取得雷達時間軸影格 (過去2小時至最新觀測/預報)
  Future<Map<String, dynamic>> fetchRadarFrames() async {
    final uri = Uri.parse('https://api.rainviewer.com/public/weather-maps.json');
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('無法載入雷達圖層索引');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final String host = data['host'] ?? 'https://tilecache.rainviewer.com';
    final List<RadarFrame> frames = [];

    final radar = data['radar'] as Map<String, dynamic>?;
    if (radar != null) {
      final past = radar['past'] as List<dynamic>? ?? [];
      final nowcast = radar['nowcast'] as List<dynamic>? ?? [];
      for (final item in [...past, ...nowcast]) {
        frames.add(RadarFrame(
          time: item['time'] as int,
          path: item['path'] as String,
        ));
      }
    }
    return {'host': host, 'frames': frames};
  }

  /// 2. 取得香港天文台 (HKO) 實時天氣報告 (氣溫、相對濕度、警告)
  Future<Map<String, dynamic>> fetchHkoCurrentWeather() async {
    final uri = Uri.parse(
      'https://data.weather.gov.hk/weatherAPI/opendata/weather.php?dataType=rhrread&lang=tc',
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('無法載入香港天文台實時天氣');
    }
    return jsonDecode(response.body) as Map<String, dynamic>;
  }

  /// 3. 取得香港天文台 (HKO) 9天預報
  Future<List<DailyForecastItem>> fetchHko9DayForecast() async {
    final uri = Uri.parse(
      'https://data.weather.gov.hk/weatherAPI/opendata/weather.php?dataType=fnd&lang=tc',
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('無法載入香港天文台 9 天預報');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final list = data['weatherForecast'] as List<dynamic>? ?? [];
    return list.map((item) {
      final rawDate = item['forecastDate']?.toString() ?? '';
      final formattedDate = rawDate.length == 8
          ? '${rawDate.substring(4, 6)}/${rawDate.substring(6, 8)}'
          : rawDate;
      return DailyForecastItem(
        date: formattedDate,
        week: item['week']?.toString() ?? '',
        minTemp: (item['forecastMintemp']?['value'] as num?)?.toInt() ?? 0,
        maxTemp: (item['forecastMaxtemp']?['value'] as num?)?.toInt() ?? 0,
        forecastWeather: item['forecastWeather']?.toString() ?? '',
        psr: item['PSR']?.toString() ?? '',
      );
    }).toList();
  }

  /// 4. 取得 Open-Meteo 亞太區逐小時預報 (自動結合 JMA / ECMWF 等高解析度模型)
  Future<List<HourlyPoint>> fetchApacHourlyForecast(LatLng location) async {
    final uri = Uri.parse(
      'https://api.open-meteo.com/v1/forecast'
      '?latitude=${location.latitude}&longitude=${location.longitude}'
      '&hourly=temperature_2m,precipitation_probability'
      '&forecast_days=2&timezone=Asia%2FHong_Kong',
    );
    final response = await http.get(uri);
    if (response.statusCode != 200) {
      throw Exception('無法載入 Open-Meteo 逐小時預報');
    }
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    final hourly = data['hourly'] as Map<String, dynamic>;
    final times = hourly['time'] as List<dynamic>;
    final temps = hourly['temperature_2m'] as List<dynamic>;
    final probs = hourly['precipitation_probability'] as List<dynamic>;

    final List<HourlyPoint> result = [];
    final int count = times.length < 24 ? times.length : 24;
    for (int i = 0; i < count; i++) {
      final rawTime = times[i].toString(); // e.g., 2026-10-25T16:00
      final hhmm = rawTime.contains('T') ? rawTime.split('T').last : rawTime;
      result.add(HourlyPoint(
        timeLabel: hhmm,
        temp: (temps[i] as num).toDouble(),
        precipProb: (probs[i] as num?)?.toInt() ?? 0,
      ));
    }
    return result;
  }
}

// ----------------------------------------------------------------------------
// 主畫面：Weather & Radar 風格（頂部互動雷達地圖 + 時間軸 + 下方分層卡片）
// ----------------------------------------------------------------------------

class WeatherRadarHomeScreen extends StatefulWidget {
  const WeatherRadarHomeScreen({super.key});

  @override
  State<WeatherRadarHomeScreen> createState() => _WeatherRadarHomeScreenState();
}

class _WeatherRadarHomeScreenState extends State<WeatherRadarHomeScreen> {
  final WeatherRepository _repo = WeatherRepository();
  final MapController _mapController = MapController();

  // 雷達狀態
  String _radarHost = 'https://tilecache.rainviewer.com';
  List<RadarFrame> _radarFrames = [];
  int _currentFrameIndex = 0;
  bool _isPlaying = false;
  Timer? _playbackTimer;

  // 天氣數據狀態
  bool _isLoading = true;
  String? _errorMessage;
  int? _hkCurrentTemp;
  int? _hkHumidity;
  List<String> _hkWarnings = [];
  List<HourlyPoint> _hourlyPoints = [];
  List<DailyForecastItem> _dailyForecasts = [];

  @override
  void initState() {
    super.initState();
    _loadAllWeatherData();
  }

  @override
  void dispose() {
    _playbackTimer?.cancel();
    super.dispose();
  }

  Future<void> _loadAllWeatherData() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final results = await Future.wait([
        _repo.fetchRadarFrames(),
        _repo.fetchHkoCurrentWeather(),
        _repo.fetchHko9DayForecast(),
        _repo.fetchApacHourlyForecast(WeatherRepository.hkCenter),
      ]);

      final radarData = results[0] as Map<String, dynamic>;
      final hkoCurrent = results[1] as Map<String, dynamic>;
      final hko9Day = results[2] as List<DailyForecastItem>;
      final apacHourly = results[3] as List<HourlyPoint>;

      // 解析香港天文台氣溫與濕度
      int? temp;
      final tempRecords = hkoCurrent['temperature']?['data'] as List<dynamic>?;
      if (tempRecords != null && tempRecords.isNotEmpty) {
        final hkoStation = tempRecords.firstWhere(
          (e) => e['place'] == '香港天文台',
          orElse: () => tempRecords.first,
        );
        temp = (hkoStation['value'] as num?)?.toInt();
      }

      int? humidity;
      final rhRecords = hkoCurrent['humidity']?['data'] as List<dynamic>?;
      if (rhRecords != null && rhRecords.isNotEmpty) {
        humidity = (rhRecords.first['value'] as num?)?.toInt();
      }

      final warnings = (hkoCurrent['warningMessage'] as List<dynamic>?)
              ?.map((e) => e.toString())
              .toList() ??
          [];

      final frames = radarData['frames'] as List<RadarFrame>;

      setState(() {
        _radarHost = radarData['host'] as String;
        _radarFrames = frames;
        _currentFrameIndex = frames.isNotEmpty ? frames.length - 1 : 0;
        _hkCurrentTemp = temp;
        _hkHumidity = humidity;
        _hkWarnings = warnings;
        _dailyForecasts = hko9Day;
        _hourlyPoints = apacHourly;
        _isLoading = false;
      });
    } catch (e) {
      setState(() {
        _errorMessage = e.toString();
        _isLoading = false;
      });
    }
  }

  void _toggleRadarPlayback() {
    if (_radarFrames.isEmpty) return;
    setState(() {
      _isPlaying = !_isPlaying;
    });

    if (_isPlaying) {
      _playbackTimer = Timer.periodic(const Duration(milliseconds: 650), (_) {
        setState(() {
          _currentFrameIndex = (_currentFrameIndex + 1) % _radarFrames.length;
        });
      });
    } else {
      _playbackTimer?.cancel();
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        backgroundColor: const Color(0xFF0F172A),
        elevation: 0,
        title: Row(
          children: [
            const Icon(Icons.radar, color: Color(0xFF38BDF8)),
            const SizedBox(width: 8),
            const Text(
              '香港及亞太氣象雷達',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
            ),
            const Spacer(),
            if (_hkCurrentTemp != null)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E293B),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(
                  '香港 $_hkCurrentTemp°C · 濕度 ${_hkHumidity ?? '--'}%',
                  style: const TextStyle(fontSize: 13, color: Color(0xFF38BDF8)),
                ),
              ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            onPressed: _loadAllWeatherData,
            tooltip: '更新氣象資料',
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _errorMessage != null
              ? Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24.0),
                    child: Text('載入失敗：$_errorMessage'),
                  ),
                )
              : RefreshIndicator(
                  onRefresh: _loadAllWeatherData,
                  child: ListView(
                    padding: const EdgeInsets.all(12),
                    children: [
                      if (_hkWarnings.isNotEmpty) _buildWarningBanner(),
                      _buildWeatherRadarCard(),
                      const SizedBox(height: 16),
                      _buildHourlyForecastCard(),
                      const SizedBox(height: 16),
                      _buildNineDayForecastCard(),
                    ],
                  ),
                ),
    );
  }

  /// 天文台實時警告橫幅
  Widget _buildWarningBanner() {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
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
              style: const TextStyle(fontSize: 13, color: Colors.amberAccent),
            ),
          ),
        ],
      ),
    );
  }

  /// 核心視覺區：Weather & Radar 風格互動雷達地圖 + 時間軸播放器
  Widget _buildWeatherRadarCard() {
    final currentFrame =
        _radarFrames.isNotEmpty ? _radarFrames[_currentFrameIndex] : null;

    return Card(
      clipBehavior: Clip.antiAlias,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 340,
            child: Stack(
              children: [
                FlutterMap(
                  mapController: _mapController,
                  options: const MapOptions(
                    initialCenter: WeatherRepository.hkCenter,
                    initialZoom: 8.5,
                    minZoom: 3.0,
                    maxZoom: 14.0,
                  ),
                  children: [
                    // 1. 深色高對比底圖 (突顯彩色降雨雷達回波)
                    TileLayer(
                      urlTemplate:
                          'https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png',
                      subdomains: const ['a', 'b', 'c', 'd'],
                      userAgentPackageName: 'hk.weather.radar.app',
                    ),
                    // 2. 動態氣象雷達 XYZ 圖層
                    if (currentFrame != null)
                      Opacity(
                        opacity: 0.72,
                        child: TileLayer(
                          key: ValueKey<String>(currentFrame.path),
                          urlTemplate:
                              '$_radarHost${currentFrame.path}/256/{z}/{x}/{y}/2/1_1.png',
                          userAgentPackageName: 'hk.weather.radar.app',
                        ),
                      ),
                    // 3. 香港中心定位標記
                    const MarkerLayer(
                      markers: [
                        Marker(
                          point: WeatherRepository.hkCenter,
                          width: 36,
                          height: 36,
                          child: Icon(
                            Icons.location_on,
                            color: Color(0xFF38BDF8),
                            size: 32,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
                // 右上角快速返回香港按鈕
                Positioned(
                  top: 12,
                  right: 12,
                  child: FloatingActionButton.small(
                    backgroundColor: const Color(0xFF1E293B).withOpacity(0.9),
                    onPressed: () {
                      _mapController.move(WeatherRepository.hkCenter, 9.5);
                    },
                    tooltip: '置中香港',
                    child: const Icon(Icons.my_location, color: Colors.white),
                  ),
                ),
              ],
            ),
          ),
          // 底部時間軸控制器
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: const Color(0xFF1E293B),
            child: Row(
              children: [
                IconButton(
                  icon: Icon(
                    _isPlaying ? Icons.pause_circle_filled : Icons.play_circle_fill,
                    color: const Color(0xFF38BDF8),
                    size: 32,
                  ),
                  onPressed: _toggleRadarPlayback,
                ),
                if (currentFrame != null)
                  SizedBox(
                    width: 48,
                    child: Text(
                      currentFrame.formattedTime,
                      style: const TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                      ),
                    ),
                  ),
                Expanded(
                  child: _radarFrames.isEmpty
                      ? const SizedBox.shrink()
                      : Slider(
                          value: _currentFrameIndex.toDouble(),
                          min: 0,
                          max: (_radarFrames.length - 1).toDouble(),
                          divisions: _radarFrames.length > 1
                              ? _radarFrames.length - 1
                              : 1,
                          onChanged: (value) {
                            setState(() {
                              _isPlaying = false;
                              _playbackTimer?.cancel();
                              _currentFrameIndex = value.round();
                            });
                          },
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// 逐小時溫濕與降雨機率橫向卡片 (Open-Meteo JMA/ECMWF 模型)
  Widget _buildHourlyForecastCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '未來 24 小時趨勢（亞太區高解析度預報）',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 96,
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
                      const SizedBox(height: 8),
                      Text(
                        '${pt.temp.toStringAsFixed(1)}°',
                        style: const TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Row(
                        children: [
                          const Icon(
                            Icons.water_drop,
                            size: 12,
                            color: Color(0xFF38BDF8),
                          ),
                          const SizedBox(width: 2),
                          Text(
                            '${pt.precipProb}%',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF38BDF8),
                            ),
                          ),
                        ],
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

  /// 香港天文台 9 天天氣預報清單
  Widget _buildNineDayForecastCard() {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              '香港天文台 9 天天氣預報',
              style: TextStyle(fontSize: 15, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            ..._dailyForecasts.map((day) {
              return Padding(
                padding: const EdgeInsets.symmetric(vertical: 8),
                child: Row(
                  children: [
                    SizedBox(
                      width: 88,
                      child: Text(
                        '${day.date} (${day.week})',
                        style: const TextStyle(fontWeight: FontWeight.w600),
                      ),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF0F172A),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text(
                        '雨量機率: ${day.psr}',
                        style: const TextStyle(
                          fontSize: 11,
                          color: Color(0xFF38BDF8),
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
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
                      '${day.minTemp}° / ${day.maxTemp}°C',
                      style: const TextStyle(fontWeight: FontWeight.bold),
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