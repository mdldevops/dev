import 'package:flutter/material.dart';

import 'services/local_db_service.dart';

enum _SalesLogFilter {
  daily,
  weekly,
  monthly,
}

class StandaloneSalesPage extends StatefulWidget {
  const StandaloneSalesPage({super.key});

  @override
  State<StandaloneSalesPage> createState() => _StandaloneSalesPageState();
}

class _StandaloneSalesPageState extends State<StandaloneSalesPage> {
  StandaloneSalesSummary _summary = const StandaloneSalesSummary(
    total: 0,
    daily: 0,
    weekly: 0,
    monthly: 0,
    averageDaily: 0,
  );
  List<StandaloneCoinSaleLog> _logs = const <StandaloneCoinSaleLog>[];
  _SalesLogFilter _logFilter = _SalesLogFilter.daily;
  bool _isLoading = true;

  int get _filterStartMillis {
    final now = DateTime.now();
    final startOfDay = DateTime(now.year, now.month, now.day);
    switch (_logFilter) {
      case _SalesLogFilter.daily:
        return startOfDay.millisecondsSinceEpoch;
      case _SalesLogFilter.weekly:
        return startOfDay
            .subtract(Duration(days: startOfDay.weekday - 1))
            .millisecondsSinceEpoch;
      case _SalesLogFilter.monthly:
        return DateTime(now.year, now.month).millisecondsSinceEpoch;
    }
  }

  List<_CoinLogDateGroup> get _groupedLogs {
    final groups = <String, _CoinLogDateGroup>{};
    for (final log in _logs) {
      final dateKey = _formatDate(log.createdAt);
      groups.putIfAbsent(dateKey, () => _CoinLogDateGroup(dateKey)).add(log);
    }
    return groups.values.toList();
  }

  @override
  void initState() {
    super.initState();
    _loadSales();
  }

  Future<void> _loadSales() async {
    final summary = await LocalDbService.instance.getStandaloneSalesSummary();
    final logs = await LocalDbService.instance.getStandaloneSaleLogs(
      fromMillis: _filterStartMillis,
      limit: 1000,
    );
    if (!mounted) {
      return;
    }
    setState(() {
      _summary = summary;
      _logs = logs;
      _isLoading = false;
    });
  }

  Future<void> _resetSales() async {
    final shouldReset = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) {
        return AlertDialog(
          backgroundColor: const Color(0xFF121212),
          title: const Text(
            'Reset Sales',
            style: TextStyle(color: Colors.white),
          ),
          content: const Text(
            'Clear all standalone sales totals and coin insert logs?',
            style: TextStyle(color: Colors.white70),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('Cancel'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('Reset'),
            ),
          ],
        );
      },
    );

    if (shouldReset != true) {
      return;
    }

    await LocalDbService.instance.resetStandaloneSales();
    await _loadSales();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF050505),
      appBar: AppBar(
        backgroundColor: const Color(0xFF111111),
        foregroundColor: Colors.white,
        title: const Text('Sales'),
        actions: [
          IconButton(
            tooltip: 'Refresh',
            onPressed: _loadSales,
            icon: const Icon(Icons.refresh),
          ),
          IconButton(
            tooltip: 'Reset sales',
            onPressed: _resetSales,
            icon: const Icon(Icons.delete_outline),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: _loadSales,
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  _SummaryGrid(
                    summary: _summary,
                  ),
                  const SizedBox(height: 20),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      const SizedBox(
                        width: 150,
                        child: Text(
                          'Coin Insert Logs',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                      _LogFilterButton(
                        label: 'Daily',
                        isSelected: _logFilter == _SalesLogFilter.daily,
                        onTap: () => _setLogFilter(_SalesLogFilter.daily),
                      ),
                      _LogFilterButton(
                        label: 'Weekly',
                        isSelected: _logFilter == _SalesLogFilter.weekly,
                        onTap: () => _setLogFilter(_SalesLogFilter.weekly),
                      ),
                      _LogFilterButton(
                        label: 'Monthly',
                        isSelected: _logFilter == _SalesLogFilter.monthly,
                        onTap: () => _setLogFilter(_SalesLogFilter.monthly),
                      ),
                    ],
                  ),
                  const SizedBox(height: 10),
                  if (_logs.isEmpty)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          'No ${_filterLabel.toLowerCase()} coin logs yet.',
                          style: const TextStyle(color: Colors.white70),
                        ),
                      ),
                    )
                  else
                    ..._groupedLogs.map(
                      (group) => _CoinLogDateSection(group: group),
                    ),
                ],
              ),
            ),
    );
  }

  String get _filterLabel {
    switch (_logFilter) {
      case _SalesLogFilter.daily:
        return 'Daily';
      case _SalesLogFilter.weekly:
        return 'Weekly';
      case _SalesLogFilter.monthly:
        return 'Monthly';
    }
  }

  Future<void> _setLogFilter(_SalesLogFilter filter) async {
    if (_logFilter == filter) {
      return;
    }
    setState(() {
      _logFilter = filter;
      _isLoading = true;
    });
    await _loadSales();
  }

  static String _formatDate(DateTime dateTime) {
    final month = dateTime.month.toString().padLeft(2, '0');
    final day = dateTime.day.toString().padLeft(2, '0');
    return '${dateTime.year}-$month-$day';
  }
}

class _CoinLogDateGroup {
  _CoinLogDateGroup(this.dateLabel);

  final String dateLabel;
  final List<StandaloneCoinSaleLog> logs = <StandaloneCoinSaleLog>[];
  int total = 0;

  void add(StandaloneCoinSaleLog log) {
    logs.add(log);
    total += log.amount;
  }
}

class _LogFilterButton extends StatelessWidget {
  const _LogFilterButton({
    required this.label,
    required this.isSelected,
    required this.onTap,
  });

  final String label;
  final bool isSelected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(6),
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected ? Colors.lightGreenAccent : const Color(0xFF151515),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSelected ? Colors.lightGreenAccent : Colors.white12,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? Colors.black : Colors.white70,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}

class _CoinLogDateSection extends StatelessWidget {
  const _CoinLogDateSection({required this.group});

  final _CoinLogDateGroup group;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: const Color(0xFF0C0C0C),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    group.dateLabel,
                    style: const TextStyle(
                      color: Colors.white,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Text(
                  'Total: ${group.total}',
                  style: const TextStyle(
                    color: Colors.lightGreenAccent,
                    fontWeight: FontWeight.w800,
                  ),
                ),
              ],
            ),
          ),
          const Divider(height: 1, color: Colors.white10),
          ...group.logs.map((log) => _CoinLogTile(log: log)),
        ],
      ),
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({
    required this.summary,
  });

  final StandaloneSalesSummary summary;

  @override
  Widget build(BuildContext context) {
    return GridView.count(
      crossAxisCount: 2,
      childAspectRatio: 2.2,
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      crossAxisSpacing: 10,
      mainAxisSpacing: 10,
      children: [
        _SummaryTile(label: 'Total', value: summary.total.toString()),
        _SummaryTile(label: 'Daily', value: summary.daily.toString()),
        _SummaryTile(label: 'Weekly', value: summary.weekly.toString()),
        _SummaryTile(label: 'Monthly', value: summary.monthly.toString()),
        _SummaryTile(
          label: 'Average Daily',
          value: summary.averageDaily.toStringAsFixed(2),
        ),
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF141414),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            label,
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              color: Colors.lightGreenAccent,
              fontSize: 22,
              fontWeight: FontWeight.w800,
            ),
          ),
        ],
      ),
    );
  }
}

class _CoinLogTile extends StatelessWidget {
  const _CoinLogTile({required this.log});

  final StandaloneCoinSaleLog log;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: const Color(0xFF101010),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.white10),
      ),
      child: ListTile(
        leading: const Icon(Icons.paid, color: Colors.amberAccent),
        title: Text(
          '${log.amount} Peso',
          style: const TextStyle(
            color: Colors.white,
            fontWeight: FontWeight.w700,
          ),
        ),
        subtitle: Text(
          _formatDateTime(log.createdAt),
          style: const TextStyle(color: Colors.white70),
        ),
        trailing: Text(
          '+${log.minutesAdded} min',
          style: const TextStyle(
            color: Colors.cyanAccent,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }

  static String _formatDateTime(DateTime dateTime) {
    final month = dateTime.month.toString().padLeft(2, '0');
    final day = dateTime.day.toString().padLeft(2, '0');
    final hour = dateTime.hour.toString().padLeft(2, '0');
    final minute = dateTime.minute.toString().padLeft(2, '0');
    final second = dateTime.second.toString().padLeft(2, '0');
    return '${dateTime.year}-$month-$day $hour:$minute:$second';
  }
}
