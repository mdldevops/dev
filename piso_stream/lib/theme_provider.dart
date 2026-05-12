import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

class ThemeProvider with ChangeNotifier {
  int _selectedThemeIndex = 0;

  final List<List<Color>> _themeGradients = [
    [const Color(0xFF0F2027), const Color(0xFF203A43)], // Dark teal to slate
    [const Color(0xFF232526), const Color(0xFF414345)], // Charcoal to gray
    [const Color(0xFF141E30), const Color(0xFF243B55)], // Navy to steel blue
    [const Color(0xFF000000), const Color(0xFF434343)], // Black to dark gray
    [
      const Color(0xFF1A1A1D),
      const Color(0xFF4E4E50),
    ], // Blackened purple to ash
    [
      const Color(0xFF2C3E50),
      const Color(0xFF000000),
    ], // Midnight blue to black
    [const Color(0xFF3C3B3F), const Color(0xFF605C3C)], // Smoky gray to bronze
    [
      const Color(0xFF1F1C2C),
      const Color(0xFF928DAB),
    ], // Deep violet to muted lavender
    [
      const Color(0xFF0D0D0D),
      const Color(0xFF3C3C3C),
    ], // Pure black to graphite
    [
      const Color(0xFF2B2B2B),
      const Color(0xFF1A1A1A),
    ], // Dark gray to near-black
  ];

  ThemeProvider() {
    _loadTheme();
  }

  List<Color> get currentTheme => _themeGradients[_selectedThemeIndex];

  int get selectedThemeIndex => _selectedThemeIndex;

  void setTheme(int index) {
    if (index >= 0 && index < _themeGradients.length) {
      _selectedThemeIndex = index;
      _saveTheme();
      notifyListeners();
    }
  }

  List<List<Color>> get themeGradients => _themeGradients;

  void _loadTheme() async {
    final prefs = await SharedPreferences.getInstance();
    _selectedThemeIndex = prefs.getInt('selectedThemeIndex') ?? 0;
    notifyListeners();
  }

  void _saveTheme() async {
    final prefs = await SharedPreferences.getInstance();
    prefs.setInt('selectedThemeIndex', _selectedThemeIndex);
  }
}
