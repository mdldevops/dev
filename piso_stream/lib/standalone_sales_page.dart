import 'package:flutter/material.dart';

import 'services/local_db_service.dart';

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
  );
  List<StandaloneCoinSaleLog> _logs = const <StandaloneCoinSaleLog>[];
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    _loadSales();
  }

  Future<void> _loadSales() async {
    final summary = await LocalDbService.instance.getStandaloneSalesSummary();
    final logs = await LocalDbService.instance.getStandaloneSaleLogs();
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
            'Reset Standalone Sales',
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
        title: const Text('Standalone Sales'),
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
                  _SummaryGrid(summary: _summary),
                  const SizedBox(height: 20),
                  const Text(
                    'Coin Insert Logs',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 10),
                  if (_logs.isEmpty)
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 32),
                      child: Center(
                        child: Text(
                          'No coin logs yet.',
                          style: TextStyle(color: Colors.white70),
                        ),
                      ),
                    )
                  else
                    ..._logs.map((log) => _CoinLogTile(log: log)),
                ],
              ),
            ),
    );
  }
}

class _SummaryGrid extends StatelessWidget {
  const _SummaryGrid({required this.summary});

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
        _SummaryTile(label: 'Total', value: summary.total),
        _SummaryTile(label: 'Daily', value: summary.daily),
        _SummaryTile(label: 'Weekly', value: summary.weekly),
        _SummaryTile(label: 'Monthly', value: summary.monthly),
      ],
    );
  }
}

class _SummaryTile extends StatelessWidget {
  const _SummaryTile({required this.label, required this.value});

  final String label;
  final int value;

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
            '$value',
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
