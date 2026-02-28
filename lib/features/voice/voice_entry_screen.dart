import 'package:drift/drift.dart' show Value;
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../core/constants/app_constants.dart';
import '../../core/theme/app_theme.dart';
import '../../data/database/app_database.dart';
import '../../data/models/parsed_entry.dart';
import '../../data/providers/app_providers.dart';
import '../../data/services/gemini_service.dart';

class VoiceEntryScreen extends ConsumerStatefulWidget {
  const VoiceEntryScreen({super.key});

  @override
  ConsumerState<VoiceEntryScreen> createState() => _VoiceEntryScreenState();
}

class _VoiceEntryScreenState extends ConsumerState<VoiceEntryScreen> {
  final TextEditingController _inputCtrl = TextEditingController();
  bool _isParsing       = false;
  List<ParsedEntry> _parsedList = [];
  String? _error;
  String _lastInput     = '';

  @override
  void dispose() {
    _inputCtrl.dispose();
    super.dispose();
  }

  Future<void> _callGemini() async {
    final text = _inputCtrl.text.trim();
    if (text.isEmpty) return;
    _lastInput = text;
    setState(() { _isParsing = true; _error = null; _parsedList = []; });
    try {
      final results = await ref.read(geminiServiceProvider).parseExpenses(text);
      if (!mounted) return;
      if (results.isEmpty) {
        setState(() {
          _error = "Couldn't detect any expenses. Try e.g. \"spent ₹200 on lunch\"";
          _isParsing = false;
        });
        return;
      }
      setState(() { _parsedList = results; _isParsing = false; });
    } on GeminiException catch (e) {
      if (mounted) setState(() { _error = e.message; _isParsing = false; });
    } catch (e) {
      if (mounted) setState(() { _error = e.toString(); _isParsing = false; });
    }
  }

  Future<void> _saveAll() async {
    if (_parsedList.isEmpty) return;
    const uuid      = Uuid();
    final accountId = ref.read(selectedAccountProvider);
    for (final entry in _parsedList) {
      await ref.read(databaseProvider).insertTransaction(
        TransactionsCompanion.insert(
          uuid: uuid.v4(),
          amount: entry.amount,
          category: entry.category,
          description: entry.description,
          date: entry.date,
          accountId: Value(accountId),
          rawInput: Value(_lastInput),
        ),
      );
    }
    if (mounted) {
      final savedCount = _parsedList.length;
      setState(() { _parsedList = []; _inputCtrl.clear(); _lastInput = ''; });
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text('$savedCount ${savedCount == 1 ? "entry" : "entries"} added'),
        backgroundColor: AppTheme.positive,
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ));
    }
  }

  @override
  Widget build(BuildContext context) {
    final tt       = Theme.of(context).textTheme;
    final cs       = Theme.of(context).colorScheme;
    final isDark   = Theme.of(context).brightness == Brightness.dark;
    final currency = ref.watch(currencyProvider);
    final bgColor  = isDark ? const Color(0xFF0A0A0A) : const Color(0xFFF5F5F5);

    // autoStartRecordingProvider is a no-op on web — just consume it silently.
    ref.listen<bool>(autoStartRecordingProvider, (_, shouldStart) {
      if (shouldStart) {
        ref.read(autoStartRecordingProvider.notifier).state = false;
      }
    });

    return Scaffold(
      backgroundColor: bgColor,
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            floating: true,
            pinned: false,
            toolbarHeight: 64,
            backgroundColor: bgColor,
            title: Text('Add Entry', style: tt.headlineMedium),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [

                  // ── Text input area ────────────────────────────────────
                  _TextInputArea(
                    controller: _inputCtrl,
                    isParsing: _isParsing,
                    cs: cs,
                    tt: tt,
                    isDark: isDark,
                    onSubmit: _callGemini,
                  ).animate().fadeIn(duration: 300.ms),

                  if (_error != null) ...[
                    const SizedBox(height: 16),
                    _ErrorBanner(error: _error!, cs: cs, tt: tt)
                        .animate().fadeIn(duration: 250.ms).slideY(begin: 0.1),
                  ],

                  if (_parsedList.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    if (_parsedList.length > 1)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: Row(
                          children: [
                            Text(
                              '${_parsedList.length} ENTRIES FOUND',
                              style: tt.labelLarge?.copyWith(letterSpacing: 1.0),
                            ),
                            const Spacer(),
                            TextButton(
                              onPressed: () => setState(() {
                                _parsedList = [];
                                _inputCtrl.clear();
                              }),
                              style: TextButton.styleFrom(
                                  foregroundColor: AppTheme.negative),
                              child: const Text('Discard All'),
                            ),
                          ],
                        ),
                      ),

                    ...List.generate(_parsedList.length, (i) => Padding(
                      padding: const EdgeInsets.only(bottom: 12),
                      child: _ConfirmCard(
                        parsed: _parsedList[i],
                        currency: currency,
                        cs: cs,
                        tt: tt,
                        isDark: isDark,
                        onCategoryChange: (c) => setState(() =>
                            _parsedList[i] = _parsedList[i].copyWith(category: c)),
                        onDateChange: (d) => setState(() =>
                            _parsedList[i] = _parsedList[i].copyWith(date: d)),
                        onSave: _parsedList.length == 1 ? _saveAll : null,
                        onDiscard: () => setState(() => _parsedList.removeAt(i)),
                      ).animate().fadeIn(duration: 350.ms).slideY(begin: 0.08),
                    )),

                    if (_parsedList.length > 1)
                      SizedBox(
                        width: double.infinity,
                        child: ElevatedButton(
                          onPressed: _saveAll,
                          child: Text('Save ${_parsedList.length} Entries'),
                        ),
                      ),
                  ],

                  const SizedBox(height: 120),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ── Text input area (replaces mic orb on web) ──────────────────────────────

class _TextInputArea extends StatelessWidget {
  final TextEditingController controller;
  final bool isParsing;
  final ColorScheme cs;
  final TextTheme tt;
  final bool isDark;
  final VoidCallback onSubmit;

  const _TextInputArea({
    required this.controller,
    required this.isParsing,
    required this.cs,
    required this.tt,
    required this.isDark,
    required this.onSubmit,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),

        // ── Input card ─────────────────────────────────────────────────
        Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF141414) : Colors.white,
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: isDark ? const Color(0xFF242424) : const Color(0xFFE8E8E8),
              width: 1,
            ),
            boxShadow: isDark
                ? null
                : [BoxShadow(
                    color: Colors.black.withAlpha(6),
                    blurRadius: 16,
                    offset: const Offset(0, 4))],
          ),
          padding: const EdgeInsets.all(20),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Hint label
              Row(children: [
                Icon(Icons.edit_note_rounded,
                    size: 18, color: cs.onSurfaceVariant),
                const SizedBox(width: 8),
                Text(
                  'Describe your expense',
                  style: tt.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                      letterSpacing: 0.3),
                ),
              ]),
              const SizedBox(height: 12),

              // Text field
              TextField(
                controller: controller,
                maxLines: 3,
                minLines: 2,
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => onSubmit(),
                style: tt.bodyLarge,
                decoration: InputDecoration(
                  hintText: 'e.g. "spent ₹450 on groceries and ₹200 on coffee"',
                  hintStyle: tt.bodyMedium?.copyWith(
                      color: cs.onSurfaceVariant.withAlpha(120)),
                  border: InputBorder.none,
                  isDense: true,
                  contentPadding: EdgeInsets.zero,
                ),
              ),
              const SizedBox(height: 16),

              // Parse button
              SizedBox(
                width: double.infinity,
                child: ElevatedButton.icon(
                  onPressed: isParsing ? null : onSubmit,
                  icon: isParsing
                      ? SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: isDark ? Colors.black : Colors.white))
                      : const Icon(Icons.auto_awesome_rounded, size: 18),
                  label: Text(isParsing ? 'Analysing...' : 'Parse with AI'),
                ),
              ),
            ],
          ),
        ),

        const SizedBox(height: 12),

        // ── Tip ───────────────────────────────────────────────────────
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          child: Text(
            'Gemini AI will detect amounts, categories and dates automatically.',
            style: tt.bodySmall?.copyWith(
                color: cs.onSurfaceVariant.withAlpha(150),
                height: 1.5),
          ),
        ),
      ],
    );
  }
}

// ── Confirm card ───────────────────────────────────────────────────────────

class _ConfirmCard extends StatelessWidget {
  final ParsedEntry parsed;
  final AppCurrency currency;
  final ColorScheme cs;
  final TextTheme tt;
  final bool isDark;
  final ValueChanged<String> onCategoryChange;
  final ValueChanged<DateTime> onDateChange;
  final VoidCallback? onSave;
  final VoidCallback onDiscard;

  const _ConfirmCard({
    required this.parsed,
    required this.currency,
    required this.cs,
    required this.tt,
    required this.isDark,
    required this.onCategoryChange,
    required this.onDateChange,
    this.onSave,
    required this.onDiscard,
  });

  @override
  Widget build(BuildContext context) {
    final color = AppTheme.categoryColors[categoryIndex(parsed.category)];
    final emoji = categoryEmoji(parsed.category);

    return Container(
      decoration: BoxDecoration(
        color: isDark ? const Color(0xFF141414) : Colors.white,
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
            color: isDark ? const Color(0xFF1E1E3C) : const Color(0xFFE5E4F0),
            width: 1),
        boxShadow: isDark
            ? null
            : [BoxShadow(color: Colors.black.withAlpha(6), blurRadius: 16, offset: const Offset(0, 4))],
      ),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                  decoration: BoxDecoration(
                    color: AppTheme.positive.withAlpha(18),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(color: AppTheme.positive.withAlpha(70)),
                  ),
                  child: Row(mainAxisSize: MainAxisSize.min, children: [
                    Icon(Icons.check_rounded, color: AppTheme.positive, size: 12),
                    const SizedBox(width: 4),
                    Text('PARSED',
                        style: TextStyle(
                            color: AppTheme.positive,
                            fontSize: 10,
                            fontWeight: FontWeight.w700,
                            letterSpacing: 0.8)),
                  ]),
                ),
                GestureDetector(
                  onTap: onDiscard,
                  child: Container(
                    width: 30, height: 30,
                    decoration: BoxDecoration(
                      color: cs.onSurface.withAlpha(8),
                      shape: BoxShape.circle,
                    ),
                    child: Icon(Icons.close_rounded,
                        size: 16, color: cs.onSurfaceVariant),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),

            Row(children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: color.withAlpha(20),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: color.withAlpha(50), width: 1),
                ),
                child: Center(child: Text(emoji,
                    style: const TextStyle(fontSize: 24))),
              ),
              const SizedBox(width: 14),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(
                  formatAmount(parsed.amount, currency),
                  style: tt.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w900,
                      letterSpacing: -0.5),
                ),
                const SizedBox(height: 2),
                Text(
                  parsed.description,
                  style: tt.bodySmall?.copyWith(
                      color: cs.onSurfaceVariant,
                      fontWeight: FontWeight.w500),
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                ),
              ])),
            ]),
            const SizedBox(height: 18),

            DropdownButtonFormField<String>(
              initialValue: categories.contains(parsed.category)
                  ? parsed.category
                  : 'Other',
              decoration: const InputDecoration(labelText: 'Category'),
              items: categories
                  .map((c) => DropdownMenuItem(
                      value: c, child: Text('${categoryEmoji(c)}  $c')))
                  .toList(),
              onChanged: (v) { if (v != null) onCategoryChange(v); },
            ),
            const SizedBox(height: 10),

            GestureDetector(
              onTap: () async {
                final picked = await showDatePicker(
                  context: context,
                  initialDate: parsed.date,
                  firstDate: DateTime(2020),
                  lastDate: DateTime.now(),
                );
                if (picked != null) onDateChange(picked);
              },
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
                decoration: BoxDecoration(
                  color: cs.onSurface.withAlpha(7),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: cs.outline, width: 1),
                ),
                child: Row(children: [
                  Icon(Icons.calendar_month_rounded,
                      size: 14, color: cs.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Text(
                    _formatDate(parsed.date),
                    style: tt.bodySmall?.copyWith(fontWeight: FontWeight.w500),
                  ),
                  const Spacer(),
                  Icon(Icons.edit_rounded, size: 12, color: cs.onSurfaceVariant),
                ]),
              ),
            ),
            const SizedBox(height: 20),

            Row(children: [
              Expanded(
                child: OutlinedButton(
                    onPressed: onDiscard,
                    child: const Text('Discard')),
              ),
              if (onSave != null) ...[
                const SizedBox(width: 12),
                Expanded(
                  child: ElevatedButton(
                      onPressed: onSave,
                      child: const Text('Save Entry')),
                ),
              ],
            ]),
          ],
        ),
      ),
    );
  }

  static String _formatDate(DateTime d) {
    const months = [
      'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun',
      'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
    ];
    return '${d.day} ${months[d.month - 1]} ${d.year}';
  }
}

// ── Error banner ───────────────────────────────────────────────────────────

class _ErrorBanner extends StatelessWidget {
  final String error;
  final ColorScheme cs;
  final TextTheme tt;
  const _ErrorBanner(
      {required this.error, required this.cs, required this.tt});

  @override
  Widget build(BuildContext context) => Container(
        width: double.infinity,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: cs.error.withAlpha(14),
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: cs.error.withAlpha(50)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Icon(Icons.error_outline_rounded, color: cs.error, size: 18),
            const SizedBox(width: 10),
            Flexible(
                child: Text(error,
                    style: tt.bodySmall?.copyWith(
                        color: cs.error, height: 1.5))),
          ],
        ),
      );
}
