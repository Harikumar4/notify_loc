import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:geocoding/geocoding.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';
import 'dart:convert';
import 'dart:async';
import 'dart:isolate';
import 'dart:ui';
import 'dart:io';

// Background task name constants
const String locationCheckTask = "locationCheckTask";
const String backgroundChannelKey = "location_alarm_background";

// Initialize workmanager in main function
void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // Initialize the notification plugin
  await _initializeNotifications();

  // Initialize Workmanager for background tasks
  await Workmanager().initialize(
    callbackDispatcher,
    isInDebugMode: false,
  );

  runApp(const MyApp());
}

// Global notification plugin instance
final FlutterLocalNotificationsPlugin flutterLocalNotificationsPlugin =
    FlutterLocalNotificationsPlugin();

// Initialize notifications
Future<void> _initializeNotifications() async {
  const AndroidInitializationSettings initializationSettingsAndroid =
      AndroidInitializationSettings('app_icon');
  
  final DarwinInitializationSettings initializationSettingsIOS =
      DarwinInitializationSettings(
    requestSoundPermission: false,
    requestBadgePermission: false,
    requestAlertPermission: false,
  );
  
  final InitializationSettings initializationSettings = InitializationSettings(
    android: initializationSettingsAndroid,
    iOS: initializationSettingsIOS,
  );
  
  await flutterLocalNotificationsPlugin.initialize(
    initializationSettings,
    onDidReceiveNotificationResponse: (NotificationResponse notificationResponse) async {
      // Handle notification action
      if (notificationResponse.payload == 'stop_alarm') {
        await _stopAlarmFromNotification();
      }
    },
  );
}

// Stop alarm from notification action
Future<void> _stopAlarmFromNotification() async {
  // Get the current alarming location
  final prefs = await SharedPreferences.getInstance();
  final currentAlarmingLocation = prefs.getString('currentAlarmingLocation');
  
  if (currentAlarmingLocation != null) {
    // Get saved locations
    final locationsJson = prefs.getStringList('savedLocations') ?? [];
    List<SavedLocation> savedLocations = [];
    
    for (var json in locationsJson) {
      savedLocations.add(SavedLocation.fromJson(jsonDecode(json)));
    }
    
    // Find and disable the alarming location
    bool updated = false;
    for (int i = 0; i < savedLocations.length; i++) {
      if (savedLocations[i].name == currentAlarmingLocation && savedLocations[i].alarmEnabled) {
        savedLocations[i].alarmEnabled = false;
        updated = true;
        break;
      }
    }
    
    // Save updated locations if changed
    if (updated) {
      final updatedLocationsJson = savedLocations.map(
        (location) => jsonEncode(location.toJson())
      ).toList();
      
      await prefs.setStringList('savedLocations', updatedLocationsJson);
    }
    
    // Clear the current alarming location
    await prefs.remove('currentAlarmingLocation');
  }
  
  // Cancel any ongoing notifications
  await flutterLocalNotificationsPlugin.cancel(0);
}

// Background task callback - must be top-level function
@pragma('vm:entry-point')
void callbackDispatcher() {
  Workmanager().executeTask((task, inputData) async {
    // Setup communication with main isolate
    final SendPort? sendPort = IsolateNameServer.lookupPortByName(backgroundChannelKey);
    
    switch (task) {
      case locationCheckTask:
        // Check for nearby locations
        print("Executing background location check");
        final success = await _checkLocationsInBackground();
        if (sendPort != null) {
          sendPort.send("Background check completed. Found nearby: $success");
        }
        break;
    }
    
    return Future.value(true);
  });
}

// Check for locations in the background
Future<bool> _checkLocationsInBackground() async {
  try {
    final prefs = await SharedPreferences.getInstance();
    final locationsJson = prefs.getStringList('savedLocations') ?? [];
    
    if (locationsJson.isEmpty) return false;
    
    List<SavedLocation> savedLocations = [];
    for (var json in locationsJson) {
      savedLocations.add(SavedLocation.fromJson(jsonDecode(json)));
    }
    
    // Filter to only enabled alarms
    savedLocations = savedLocations.where((location) => location.alarmEnabled).toList();
    if (savedLocations.isEmpty) return false;
    
    // Check if location service is enabled
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) return false;
    
    // Check permissions
    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
      return false;
    }
    
    // Get current position
    Position currentPosition = await Geolocator.getCurrentPosition(
      desiredAccuracy: LocationAccuracy.high,
    );
    
    // Check if near any saved locations
    final now = DateTime.now();
    bool nearbyLocationFound = false;
    
    for (var location in savedLocations) {
      double distanceInMeters = Geolocator.distanceBetween(
        currentPosition.latitude,
        currentPosition.longitude,
        location.latitude,
        location.longitude,
      );
      
      // Check if we've already alarmed this location recently (within 5 minutes)
      String lastAlarmTimeKey = 'lastAlarm_${location.name}';
      String? lastAlarmTimeStr = prefs.getString(lastAlarmTimeKey);
      bool recentlyAlarmed = false;
      
      if (lastAlarmTimeStr != null) {
        final lastTime = DateTime.parse(lastAlarmTimeStr);
        recentlyAlarmed = now.difference(lastTime).inMinutes < 5;
      }
      
      // If within 100 meters and hasn't been alarmed recently
      if (distanceInMeters <= 100 && !recentlyAlarmed) {
        // Update last alarm time
        await prefs.setString(lastAlarmTimeKey, now.toIso8601String());
        
        // Save the current alarming location
        await prefs.setString('currentAlarmingLocation', location.name);
        
        // Show notification with stop button
        await _showAlarmNotification(location.name);
        
        nearbyLocationFound = true;
        break;
      }
    }
    
    return nearbyLocationFound;
  } catch (e) {
    print("Error in background location check: $e");
    return false;
  }
}

// Show notification with stop button
Future<void> _showAlarmNotification(String locationName) async {
  // Create notification action buttons for Android (not supported directly in 9.1.0)
  const AndroidNotificationDetails androidDetails = AndroidNotificationDetails(
    'location_alarm_channel',
    'Location Alarms',
    channelDescription: 'Notifications for location-based alarms',
    importance: Importance.high,
    priority: Priority.high,
    sound: RawResourceAndroidNotificationSound('alarm'),
    playSound: true,
    ongoing: true,
    autoCancel: false,
  );
  
  const DarwinNotificationDetails iosDetails = DarwinNotificationDetails(
    presentAlert: true,
    presentBadge: true,
    presentSound: true,
    sound: 'alarm.aiff',
    interruptionLevel: InterruptionLevel.timeSensitive,
  );
  
  const NotificationDetails notificationDetails = NotificationDetails(
    android: androidDetails,
    iOS: iosDetails,
  );
  
  await flutterLocalNotificationsPlugin.show(
    0,
    'Location Alarm',
    'You are near $locationName!',
    notificationDetails,
    payload: 'stop_alarm',
  );
}

class MyApp extends StatelessWidget {
  const MyApp({Key? key}) : super(key: key);

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Location Alarm',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        primaryColor: Colors.deepPurple,
        colorScheme: ColorScheme.dark(
          primary: Colors.deepPurple,
          secondary: Colors.purpleAccent,
          surface: Colors.grey[900]!,
          background: Colors.black,
        ),
        scaffoldBackgroundColor: Colors.black,
        cardTheme: CardTheme(
          color: Colors.grey[850],
          elevation: 4,
          margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
        ),
        appBarTheme: AppBarTheme(
          backgroundColor: Colors.grey[900],
          elevation: 0,
        ),
        inputDecorationTheme: InputDecorationTheme(
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(8),
            borderSide: BorderSide(color: Colors.purpleAccent, width: 2),
          ),
          filled: true,
          fillColor: Colors.grey[800],
        ),
        elevatedButtonTheme: ElevatedButtonThemeData(
          style: ElevatedButton.styleFrom(
            backgroundColor: Colors.deepPurple,
            foregroundColor: Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
          ),
        ),
        switchTheme: SwitchThemeData(
          thumbColor: MaterialStateProperty.resolveWith<Color>((states) {
            if (states.contains(MaterialState.selected)) {
              return Colors.purpleAccent;
            }
            return Colors.grey[400]!;
          }),
          trackColor: MaterialStateProperty.resolveWith<Color>((states) {
            if (states.contains(MaterialState.selected)) {
              return Colors.purple.withOpacity(0.5);
            }
            return Colors.grey.withOpacity(0.5);
          }),
        ),
        dialogTheme: DialogTheme(
          backgroundColor: Colors.grey[850],
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      home: const LocationAlarmHome(),
    );
  }
}

class SavedLocation {
  final String name;
  final double latitude;
  final double longitude;
  bool alarmEnabled;

  SavedLocation({
    required this.name,
    required this.latitude,
    required this.longitude,
    this.alarmEnabled = false,
  });

  Map<String, dynamic> toJson() {
    return {
      'name': name,
      'latitude': latitude,
      'longitude': longitude,
      'alarmEnabled': alarmEnabled,
    };
  }

  factory SavedLocation.fromJson(Map<String, dynamic> json) {
    return SavedLocation(
      name: json['name'],
      latitude: json['latitude'],
      longitude: json['longitude'],
      alarmEnabled: json['alarmEnabled'],
    );
  }
}

class LocationAlarmHome extends StatefulWidget {
  const LocationAlarmHome({Key? key}) : super(key: key);

  @override
  _LocationAlarmHomeState createState() => _LocationAlarmHomeState();
}

class _LocationAlarmHomeState extends State<LocationAlarmHome> with WidgetsBindingObserver {
  final TextEditingController _locationController = TextEditingController();
  final List<SavedLocation> _savedLocations = [];
  bool _isLocationServiceEnabled = false;
  bool _isPermissionGranted = false;
  Position? _currentPosition;
  final AudioPlayer _audioPlayer = AudioPlayer();
  bool _isBackgroundTaskRegistered = false;
  final ReceivePort _port = ReceivePort();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    
    // Register the receive port for background communication
    IsolateNameServer.registerPortWithName(
      _port.sendPort, 
      backgroundChannelKey
    );
    
    // Set up port listener for debugging
    _port.listen((message) {
      print("Message from background: $message");
    });
    
    _checkLocationPermission();
    _loadSavedLocations();
    _requestNotificationPermission();
    
    // Check for any active alarms that might have been triggered while app was closed
    _checkForActiveAlarms();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _locationController.dispose();
    _audioPlayer.dispose();
    IsolateNameServer.removePortNameMapping(backgroundChannelKey);
    _port.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // App came to the foreground
      _getCurrentLocation();
      _checkForActiveAlarms();
    } else if (state == AppLifecycleState.paused) {
      // App went to the background
      _updateBackgroundTaskRegistration();
    }
  }

  // Request notification permission
  Future<void> _requestNotificationPermission() async {
    // For Android
    if (Platform.isAndroid) {
      final AndroidFlutterLocalNotificationsPlugin? androidImplementation =
          flutterLocalNotificationsPlugin
              .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>();
      
      if (androidImplementation != null) {
        await androidImplementation.requestPermission();
      }
    }
    
    // For iOS
    if (Platform.isIOS) {
      await flutterLocalNotificationsPlugin
          .resolvePlatformSpecificImplementation<DarwinFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          );
    }
  }

  // Check for any active alarms
  Future<void> _checkForActiveAlarms() async {
    final prefs = await SharedPreferences.getInstance();
    final currentAlarmingLocation = prefs.getString('currentAlarmingLocation');
    
    if (currentAlarmingLocation != null) {
      // Show the alarm dialog for the active alarm
      _showAlarmDialog(currentAlarmingLocation);
    }
  }

  // Show alarm dialog
  void _showAlarmDialog(String locationName) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Location Alarm'),
          content: Text('You are near $locationName!'),
          actions: <Widget>[
            TextButton(
              child: const Text('Stop Alarm'),
              onPressed: () {
                _stopAlarm(locationName);
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  // Update background task registration based on enabled alarms
  Future<void> _updateBackgroundTaskRegistration() async {
    bool hasEnabledAlarms = _savedLocations.any((location) => location.alarmEnabled);
    
    if (hasEnabledAlarms && !_isBackgroundTaskRegistered) {
      // Register the background task
      await Workmanager().registerPeriodicTask(
        "locationCheck",
        locationCheckTask,
        frequency: const Duration(minutes: 15),
        constraints: Constraints(
          networkType: NetworkType.not_required,
          requiresBatteryNotLow: false,
          requiresCharging: false,
          requiresDeviceIdle: false,
          requiresStorageNotLow: false,
        ),
        existingWorkPolicy: ExistingWorkPolicy.replace,
        backoffPolicy: BackoffPolicy.linear,
        backoffPolicyDelay: const Duration(minutes: 1),
      );
      
      setState(() {
        _isBackgroundTaskRegistered = true;
      });
      
      print("Background task registered");
    } else if (!hasEnabledAlarms && _isBackgroundTaskRegistered) {
      // Cancel the background task if no alarms are enabled
      await Workmanager().cancelByUniqueName("locationCheck");
      
      setState(() {
        _isBackgroundTaskRegistered = false;
      });
      
      print("Background task canceled");
    }
  }

  // Check and request location permissions
  Future<void> _checkLocationPermission() async {
    bool serviceEnabled = await Geolocator.isLocationServiceEnabled();
    if (!serviceEnabled) {
      setState(() {
        _isLocationServiceEnabled = false;
      });
      _showPermissionDialog('Location services are disabled. Please enable location services to use this app.');
      return;
    }

    LocationPermission permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied) {
        setState(() {
          _isPermissionGranted = false;
        });
        _showPermissionDialog('Location permissions are denied. Please grant location permissions to use this app.');
        return;
      }
    }

    if (permission == LocationPermission.deniedForever) {
      setState(() {
        _isPermissionGranted = false;
      });
      _showPermissionDialog(
        'Location permissions are permanently denied. Please enable them in app settings.',
      );
      return;
    }

    setState(() {
      _isLocationServiceEnabled = true;
      _isPermissionGranted = true;
    });
    _getCurrentLocation();
  }

  void _showPermissionDialog(String message) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) {
        return AlertDialog(
          title: const Text('Location Permission Required'),
          content: Text(message),
          actions: <Widget>[
            TextButton(
              child: const Text('OK'),
              onPressed: () {
                Navigator.of(context).pop();
                _checkLocationPermission();
              },
            ),
            TextButton(
              child: const Text('Open Settings'),
              onPressed: () {
                Geolocator.openAppSettings();
                Navigator.of(context).pop();
              },
            ),
          ],
        );
      },
    );
  }

  // Get current location
  Future<void> _getCurrentLocation() async {
    try {
      Position position = await Geolocator.getCurrentPosition(
        desiredAccuracy: LocationAccuracy.high,
      );
      setState(() {
        _currentPosition = position;
      });
    } catch (e) {
      print("Error getting location: $e");
    }
  }

  // Load saved locations from SharedPreferences
  Future<void> _loadSavedLocations() async {
    final prefs = await SharedPreferences.getInstance();
    final locationsJson = prefs.getStringList('savedLocations') ?? [];
    
    setState(() {
      _savedLocations.clear();
      for (var json in locationsJson) {
        _savedLocations.add(SavedLocation.fromJson(jsonDecode(json)));
      }
    });
    
    // Update the background task
    _updateBackgroundTaskRegistration();
  }

  // Save locations to SharedPreferences
  Future<void> _saveLocations() async {
    final prefs = await SharedPreferences.getInstance();
    final locationsJson = _savedLocations.map(
      (location) => jsonEncode(location.toJson())
    ).toList();
    
    await prefs.setStringList('savedLocations', locationsJson);
    
    // Update the background task registration
    _updateBackgroundTaskRegistration();
  }

  // Add new location
  Future<void> _addLocation() async {
    if (_locationController.text.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a location name')),
      );
      return;
    }

    try {
      // Search for location coordinates using the entered text
      List<Location> locations = await locationFromAddress(_locationController.text);
      
      if (locations.isNotEmpty) {
        // Use the first result
        Location location = locations.first;
        
        // Create a new SavedLocation
        SavedLocation newLocation = SavedLocation(
          name: _locationController.text,
          latitude: location.latitude,
          longitude: location.longitude,
        );
        
        setState(() {
          _savedLocations.add(newLocation);
          _locationController.clear();
        });
        
        await _saveLocations();
        
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Location "${newLocation.name}" added')),
        );
      }
    } catch (e) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Error finding location: $e')),
      );
    }
  }

  // Toggle alarm for a location
  void _toggleAlarm(int index) {
    setState(() {
      _savedLocations[index].alarmEnabled = !_savedLocations[index].alarmEnabled;
    });
    _saveLocations();
  }

  // Delete a location
  void _deleteLocation(int index) {
    setState(() {
      _savedLocations.removeAt(index);
    });
    _saveLocations();
  }

  // Stop alarm and disable the toggle for the location
  void _stopAlarm(String locationName) async {
    // Cancel notification
    await flutterLocalNotificationsPlugin.cancel(0);
    
    // Find and disable the toggle for the location that triggered the alarm
    bool updated = false;
    for (int i = 0; i < _savedLocations.length; i++) {
      if (_savedLocations[i].name == locationName && _savedLocations[i].alarmEnabled) {
        setState(() {
          _savedLocations[i].alarmEnabled = false;
          updated = true;
        });
        
        // Show feedback to the user
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Alarm for $locationName has been disabled')),
        );
        break;
      }
    }
    
    if (updated) {
      await _saveLocations();
    }
    
    // Clear the current alarming location
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('currentAlarmingLocation');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Location Alarm'),
        centerTitle: true,
        elevation: 0,
        actions: [
          IconButton(
            icon: const Icon(Icons.info_outline),
            onPressed: _showInfoDialog,
            tooltip: 'About',
          ),
        ],
      ),
      body: _isPermissionGranted && _isLocationServiceEnabled
          ? _buildMainContent()
          : _buildPermissionRequest(),
    );
  }

  void _showInfoDialog() {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('About Location Alarm'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: const [
            Text('This app will notify you when you are near saved locations.'),
            SizedBox(height: 12),
            Text('• Alarms will work even when the app is closed'),
            Text('• You can stop alarms directly from notifications'),
            Text('• Battery optimization is enabled to reduce power usage'),
            SizedBox(height: 12),
            Text('Enable location permissions and allow notifications for the best experience.'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('OK'),
          ),
        ],
      ),
    );
  }

  Widget _buildPermissionRequest() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          const Icon(Icons.location_off, size: 80, color: Colors.grey),
          const SizedBox(height: 16),
          const Text(
            'Location Permission Required',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 8),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 32),
            child: Text(
              'This app needs access to your location to notify you when you\'re near your saved locations.',
              textAlign: TextAlign.center,
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton(
            onPressed: _checkLocationPermission,
            child: const Text('Grant Permission'),
          ),
        ],
      ),
    );
  }

  Widget _buildMainContent() {
    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          // Add new location
          TextField(
            controller: _locationController,
            decoration: InputDecoration(
              labelText: 'Enter location name or address',
              suffixIcon: IconButton(
                icon: const Icon(Icons.add),
                onPressed: _addLocation,
              ),
              border: const OutlineInputBorder(),
            ),
          ),
          const SizedBox(height: 16),
          // Current location display
          if (_currentPosition != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12.0),
                child: Row(
                  children: [
                    const Icon(Icons.my_location, color: Colors.purpleAccent),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          const Text(
                            'Your current location:',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text(
                            'Lat: ${_currentPosition!.latitude.toStringAsFixed(6)}, '
                            'Lng: ${_currentPosition!.longitude.toStringAsFixed(6)}',
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      icon: const Icon(Icons.refresh),
                      onPressed: _getCurrentLocation,
                      tooltip: 'Refresh location',
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          // Header for saved locations
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              children: const [
                Icon(Icons.bookmark, color: Colors.purpleAccent),
                SizedBox(width: 8),
                Text(
                  'Saved Locations',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          // Saved locations list
          Expanded(
            child: _savedLocations.isEmpty
                ? Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: const [
                        Icon(Icons.location_on_outlined, size: 64, color: Colors.grey),
                        SizedBox(height: 16),
                        Text(
                          'No saved locations',
                          style: TextStyle(fontSize: 18, color: Colors.grey),
                        ),
                        Text(
                          'Add a location using the field above',
                          style: TextStyle(color: Colors.grey),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    itemCount: _savedLocations.length,
                    itemBuilder: (context, index) {
                      final location = _savedLocations[index];
                      return Card(
                        child: ListTile(
                          leading: Icon(
                            Icons.location_on,
                            color: location.alarmEnabled ? Colors.purpleAccent : Colors.grey,
                          ),
                          title: Text(location.name),
                          subtitle: Text(
                            'Lat: ${location.latitude.toStringAsFixed(6)}, '
                            'Lng: ${location.longitude.toStringAsFixed(6)}',
                          ),
                          trailing: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Switch(
                                value: location.alarmEnabled,
                                onChanged: (value) => _toggleAlarm(index),
                              ),
                              IconButton(
                                icon: const Icon(Icons.delete, color: Colors.redAccent),
                                onPressed: () => _deleteLocation(index),
                                tooltip: 'Delete location',
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}