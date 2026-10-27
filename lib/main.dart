import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:printing/printing.dart';

void main() => runApp(const LoadPlannerApp());

const double _e = 1e-6;
const List<Color> _colors = [
  Colors.indigo,
  Colors.orange,
  Colors.teal,
  Colors.pink,
  Colors.brown,
  Colors.green,
  Colors.purple,
  Colors.blueGrey,
];

class LoadPlannerApp extends StatelessWidget {
  const LoadPlannerApp({super.key});
  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'مخطط التحميل',
      theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
      builder: (context, child) =>
          Directionality(textDirection: TextDirection.rtl, child: child!),
      home: const PlannerPage(),
    );
  }
}

// ======================= النماذج =======================

class ItemSpec {
  final String name;
  final double l, w, h, weight;
  final int qty, maxStack;
  final Color color;
  ItemSpec({
    required this.name,
    required this.l,
    required this.w,
    required this.h,
    required this.weight,
    required this.qty,
    required this.maxStack,
    required this.color,
  });
}

class Placed {
  final double x, y, w, h;
  final int item, units;
  Placed(this.x, this.y, this.w, this.h, this.item, this.units);
}

class PackResult {
  final List<Placed> placed;
  final List<int> loaded;
  PackResult(this.placed, this.loaded);
  int get total => loaded.fold(0, (a, b) => a + b);
  bool betterThan(PackResult o) =>
      total > o.total || (total == o.total && placed.length < o.placed.length);
}

class Calc {
  final PackResult result;
  final double L, W, H, payload;
  final List<ItemSpec> items;
  Calc(this.result, this.L, this.W, this.H, this.payload, this.items);
}

class FreeRect {
  double x, y, w, h;
  FreeRect(this.x, this.y, this.w, this.h);
}

class Stats {
  final double volPct, floorPct, weight, usedLen;
  Stats(this.volPct, this.floorPct, this.weight, this.usedLen);
}

Stats calcStats(Calc c) {
  final r = c.result;
  double vol = 0, wt = 0, floor = 0, used = 0;
  for (var i = 0; i < c.items.length; i++) {
    final it = c.items[i];
    vol += r.loaded[i] * it.l * it.w * it.h;
    wt += r.loaded[i] * it.weight;
  }
  for (final p in r.placed) {
    floor += p.w * p.h;
    used = max(used, p.x + p.w);
  }
  return Stats(vol / (c.L * c.W * c.H) * 100, floor / (c.L * c.W) * 100, wt, used);
}

class RowInfo {
  final double x;
  double len = 0;
  final Map<int, int> units = {};
  final Map<int, int> stacks = {};
  RowInfo(this.x);
}

List<RowInfo> buildRows(List<Placed> placed) {
  final s = [...placed]..sort((a, b) {
      final d = a.x.compareTo(b.x);
      return d != 0 ? d : a.y.compareTo(b.y);
    });
  final rows = <RowInfo>[];
  for (final p in s) {
    if (rows.isEmpty || (p.x - rows.last.x).abs() > 1.0) {
      rows.add(RowInfo(p.x));
    }
    final r = rows.last;
    r.len = max(r.len, p.w);
    r.units[p.item] = (r.units[p.item] ?? 0) + p.units;
    r.stacks[p.item] = (r.stacks[p.item] ?? 0) + 1;
  }
  return rows;
}

String _n(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

// ======================= خوارزمية الترتيب (MaxRects) =======================

class MaxRects {
  final double binW, binH;
  final List<FreeRect> free = [];
  MaxRects(this.binW, this.binH) {
    free.add(FreeRect(0, 0, binW, binH));
  }

  FreeRect? insert(double w, double h, int rotMode, int heur) {
    final orients = rotMode == 0
        ? [
            [w, h],
            [h, w]
          ]
        : rotMode == 1
            ? [
                [w, h]
              ]
            : [
                [h, w]
              ];
    FreeRect? best;
    double s1 = double.infinity, s2 = double.infinity;
    for (final f in free) {
      for (final o in orients) {
        final rw = o[0], rh = o[1];
        if (rw <= f.w + _e && rh <= f.h + _e) {
          final lw = f.w - rw, lh = f.h - rh;
          double a, b;
          if (heur == 0) {
            a = min(lw, lh);
            b = max(lw, lh);
          } else if (heur == 1) {
            a = f.w * f.h - rw * rh;
            b = min(lw, lh);
          } else {
            a = f.y + rh;
            b = f.x;
          }
          if (a < s1 - _e || ((a - s1).abs() <= _e && b < s2)) {
            s1 = a;
            s2 = b;
            best = FreeRect(f.x, f.y, rw, rh);
          }
        }
      }
    }
    if (best == null) return null;
    _split(best);
    _prune();
    return best;
  }

  void _split(FreeRect u) {
    final out = <FreeRect>[];
    for (final f in free) {
      if (u.x >= f.x + f.w - _e ||
          u.x + u.w <= f.x + _e ||
          u.y >= f.y + f.h - _e ||
          u.y + u.h <= f.y + _e) {
        out.add(f);
        continue;
      }
      if (u.x > f.x + _e) {
        out.add(FreeRect(f.x, f.y, u.x - f.x, f.h));
      }
      if (u.x + u.w < f.x + f.w - _e) {
        out.add(FreeRect(u.x + u.w, f.y, f.x + f.w - (u.x + u.w), f.h));
      }
      if (u.y > f.y + _e) {
        out.add(FreeRect(f.x, f.y, f.w, u.y - f.y));
      }
      if (u.y + u.h < f.y + f.h - _e) {
        out.add(FreeRect(f.x, u.y + u.h, f.w, f.y + f.h - (u.y + u.h)));
      }
    }
    free
      ..clear()
      ..addAll(out);
  }

  bool _contains(FreeRect a, FreeRect b) =>
      b.x >= a.x - _e &&
      b.y >= a.y - _e &&
      b.x + b.w <= a.x + a.w + _e &&
      b.y + b.h <= a.y + a.h + _e;

  void _prune() {
    for (int i = 0; i < free.length; i++) {
      for (int j = i + 1; j < free.length; j++) {
        if (_contains(free[i], free[j])) {
          free.removeAt(j);
          j--;
        } else if (_contains(free[j], free[i])) {
          free.removeAt(i);
          i--;
          break;
        }
      }
    }
  }
}

PackResult pack(double L, double W, double H, List<ItemSpec> items, int heur,
    int rotMode, int order) {
  final bin = MaxRects(L, W);
  final idx = List<int>.generate(items.length, (i) => i);
  idx.sort((a, b) {
    final fa = items[a].qty == 0, fb = items[b].qty == 0;
    if (fa != fb) return fa ? 1 : -1;
    final x = order == 0
        ? items[a].l * items[a].w
        : max(items[a].l, items[a].w);
    final y = order == 0
        ? items[b].l * items[b].w
        : max(items[b].l, items[b].w);
    return y.compareTo(x);
  });
  final placed = <Placed>[];
  final loaded = List<int>.filled(items.length, 0);
  for (final i in idx) {
    final it = items[i];
    final k = min(it.maxStack, (H / it.h + 1e-9).floor());
    if (k < 1) continue;
    var remaining = it.qty <= 0 ? (1 << 30) : it.qty;
    while (remaining > 0) {
      final r = bin.insert(it.l, it.w, rotMode, heur);
      if (r == null) break;
      final u = min(k, remaining);
      placed.add(Placed(r.x, r.y, r.w, r.h, i, u));
      loaded[i] += u;
      remaining -= u;
    }
  }
  return PackResult(placed, loaded);
}

// ======================= تقرير PDF =======================

PdfColor _pc(Color c) => PdfColor.fromInt(c.toARGB32());

pw.Widget _c(String t,
    {bool bold = false,
    PdfColor? bg,
    bool ltr = false,
    double fs = 9.5,
    pw.Alignment al = pw.Alignment.center}) {
  return pw.Container(
    color: bg,
    padding: const pw.EdgeInsets.symmetric(horizontal: 4, vertical: 4),
    alignment: al,
    child: pw.Text(
      t,
      textDirection: ltr ? pw.TextDirection.ltr : null,
      style: pw.TextStyle(
          fontSize: fs,
          fontWeight: bold ? pw.FontWeight.bold : pw.FontWeight.normal),
    ),
  );
}

String _dateNow() {
  final d = DateTime.now();
  return '${d.year}/${d.month.toString().padLeft(2, '0')}/${d.day.toString().padLeft(2, '0')}';
}

String _rowText(RowInfo r, List<ItemSpec> items) {
  final parts = <String>[];
  r.units.forEach((i, u) {
    final it = items[i];
    final st = r.stacks[i] ?? 0;
    parts.add('${it.name} ${_n(it.l)}×${_n(it.w)}: $u جهاز ($st عمود)');
  });
  return parts.join('   |   ');
}

pw.Widget _topViewPdf(Calc c, List<RowInfo> rows, double maxW, double maxH) {
  final s = min(maxW / c.L, maxH / c.W);
  final cw = c.L * s, ch = c.W * s;
  const top = 16.0;
  final kids = <pw.Widget>[];

  kids.add(pw.Positioned(
    left: 0,
    top: top,
    child: pw.Container(
      width: cw,
      height: ch,
      decoration: pw.BoxDecoration(
        color: PdfColors.grey200,
        border: pw.Border.all(color: PdfColors.black, width: 1.5),
      ),
    ),
  ));

  for (final p in c.result.placed) {
    final it = c.items[p.item];
    final w = p.w * s, h = p.h * s;
    final showText = w >= 22 && h >= 12;
    kids.add(pw.Positioned(
      left: p.x * s,
      top: top + p.y * s,
      child: pw.Container(
        width: w,
        height: h,
        alignment: pw.Alignment.center,
        decoration: pw.BoxDecoration(
          color: _pc(it.color),
          border: pw.Border.all(color: PdfColors.grey900, width: 0.5),
        ),
        child: showText
            ? pw.Column(
                mainAxisSize: pw.MainAxisSize.min,
                children: [
                  pw.Text('${_n(p.w)}×${_n(p.h)}',
                      textDirection: pw.TextDirection.ltr,
                      style: const pw.TextStyle(
                          fontSize: 7, color: PdfColors.white)),
                  if (p.units > 1 && h >= 20)
                    pw.Text('x${p.units}',
                        textDirection: pw.TextDirection.ltr,
                        style: pw.TextStyle(
                            fontSize: 8,
                            color: PdfColors.white,
                            fontWeight: pw.FontWeight.bold)),
                ],
              )
            : null,
      ),
    ));
  }

  for (var i = 0; i < rows.length; i++) {
    final r = rows[i];
    kids.add(pw.Positioned(
      left: r.x * s,
      top: 0,
      child: pw.SizedBox(
        width: r.len * s,
        child: pw.Center(
          child: pw.Text('${i + 1}',
              textDirection: pw.TextDirection.ltr,
              style: pw.TextStyle(fontSize: 8, fontWeight: pw.FontWeight.bold)),
        ),
      ),
    ));
  }

  kids.add(pw.Positioned(
    left: cw - 2,
    top: top,
    child: pw.Container(width: 4, height: ch, color: PdfColors.red),
  ));
  kids.add(pw.Positioned(
    left: cw - 40,
    top: top + ch + 4,
    child: pw.Text('الباب',
        style: pw.TextStyle(
            fontSize: 9, color: PdfColors.red, fontWeight: pw.FontWeight.bold)),
  ));
  kids.add(pw.Positioned(
    left: 0,
    top: top + ch + 4,
    child: pw.Text('مقدمة الحاوية (أول صف)',
        style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
  ));

  return pw.SizedBox(
    width: cw,
    height: top + ch + 22,
    child: pw.Stack(children: kids),
  );
}

Future<Uint8List> buildReport(Calc c,
    {required pw.Font regular,
    required pw.Font bold,
    required String customer,
    required String vehicleNo,
    required String vehicleType}) async {
  final doc = pw.Document();
  final theme = pw.ThemeData.withFont(base: regular, bold: bold);
  final st = calcStats(c);
  final rows = buildRows(c.result.placed);
  final rem = max(0.0, c.L - st.usedLen);
  final overweight = c.payload > 0 && st.weight > c.payload;
  final hdrBg = PdfColors.grey300;
  final lblBg = PdfColors.grey200;

  // ---------- الورقة 1: التفاصيل ----------
  doc.addPage(pw.MultiPage(
    pageFormat: PdfPageFormat.a4,
    margin: const pw.EdgeInsets.all(28),
    textDirection: pw.TextDirection.rtl,
    theme: theme,
    build: (ctx) => [
      pw.Center(
        child: pw.Text('بيان تحميل',
            style: pw.TextStyle(fontSize: 22, fontWeight: pw.FontWeight.bold)),
      ),
      pw.SizedBox(height: 10),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.6),
        columnWidths: {
          0: pw.FlexColumnWidth(1.4),
          1: pw.FlexColumnWidth(2),
          2: pw.FlexColumnWidth(1.4),
          3: pw.FlexColumnWidth(2),
        },
        children: [
          pw.TableRow(children: [
            _c('العميل', bold: true, bg: lblBg),
            _c(customer.isEmpty ? '-' : customer),
            _c('التاريخ', bold: true, bg: lblBg),
            _c(_dateNow(), ltr: true),
          ]),
          pw.TableRow(children: [
            _c('رقم الحاوية / السيارة', bold: true, bg: lblBg),
            _c(vehicleNo.isEmpty ? '-' : vehicleNo, ltr: true),
            _c('النوع', bold: true, bg: lblBg),
            _c(vehicleType),
          ]),
          pw.TableRow(children: [
            _c('مقاسات الحاوية (سم)', bold: true, bg: lblBg),
            _c('${_n(c.L)} × ${_n(c.W)} × ${_n(c.H)}', ltr: true),
            _c('إجمالي المحمّل', bold: true, bg: lblBg),
            _c('${c.result.total} جهاز', bold: true),
          ]),
          pw.TableRow(children: [
            _c('الطول المستخدم (سم)', bold: true, bg: lblBg),
            _c(_n(double.parse(st.usedLen.toStringAsFixed(1))), ltr: true),
            _c('الطول المتبقي (سم)', bold: true, bg: lblBg),
            _c(_n(double.parse(rem.toStringAsFixed(1))), ltr: true),
          ]),
          pw.TableRow(children: [
            _c('استغلال الأرضية', bold: true, bg: lblBg),
            _c('${st.floorPct.toStringAsFixed(0)}%', ltr: true),
            _c('استغلال الحجم', bold: true, bg: lblBg),
            _c('${st.volPct.toStringAsFixed(0)}%', ltr: true),
          ]),
          pw.TableRow(children: [
            _c('الوزن الكلي (كجم)', bold: true, bg: lblBg),
            _c(st.weight > 0 ? st.weight.toStringAsFixed(0) : '-', ltr: true),
            _c('الحمولة القصوى (كجم)', bold: true, bg: lblBg),
            _c(c.payload > 0 ? c.payload.toStringAsFixed(0) : '-', ltr: true),
          ]),
        ],
      ),
      if (overweight)
        pw.Padding(
          padding: const pw.EdgeInsets.only(top: 6),
          child: pw.Text('تنبيه: الوزن الكلي أكبر من الحمولة القصوى!',
              style: pw.TextStyle(
                  color: PdfColors.red,
                  fontSize: 11,
                  fontWeight: pw.FontWeight.bold)),
        ),
      pw.SizedBox(height: 14),
      pw.Text('ملخص الأنواع',
          style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 4),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.6),
        columnWidths: {
          0: pw.FixedColumnWidth(24),
          1: pw.FlexColumnWidth(2),
          2: pw.FlexColumnWidth(2.2),
          3: pw.FlexColumnWidth(1.3),
          4: pw.FlexColumnWidth(1.3),
          5: pw.FlexColumnWidth(1.2),
          6: pw.FlexColumnWidth(1.1),
          7: pw.FlexColumnWidth(1.4),
        },
        children: [
          pw.TableRow(
            decoration: pw.BoxDecoration(color: hdrBg),
            children: [
              _c('م', bold: true),
              _c('الصنف', bold: true),
              _c('المقاس (سم)', bold: true),
              _c('المطلوب', bold: true),
              _c('المحمّل', bold: true),
              _c('الباقي', bold: true),
              _c('الطبقات', bold: true),
              _c('الوزن (كجم)', bold: true),
            ],
          ),
          for (var i = 0; i < c.items.length; i++)
            pw.TableRow(children: [
              _c('${i + 1}', ltr: true),
              _c(c.items[i].name),
              _c('${_n(c.items[i].l)}×${_n(c.items[i].w)}×${_n(c.items[i].h)}',
                  ltr: true),
              _c(c.items[i].qty == 0 ? 'أقصى كمية' : '${c.items[i].qty}'),
              _c('${c.result.loaded[i]}', bold: true),
              _c(c.items[i].qty == 0
                  ? '-'
                  : '${max(0, c.items[i].qty - c.result.loaded[i])}'),
              _c('${c.items[i].maxStack}'),
              _c(c.items[i].weight > 0
                  ? (c.result.loaded[i] * c.items[i].weight).toStringAsFixed(0)
                  : '-'),
            ]),
        ],
      ),
      pw.SizedBox(height: 14),
      pw.Text('تفاصيل الصفوف (بالترتيب اللي بيتحمّل بيه)',
          style: pw.TextStyle(fontSize: 13, fontWeight: pw.FontWeight.bold)),
      pw.SizedBox(height: 4),
      pw.Table(
        border: pw.TableBorder.all(color: PdfColors.grey600, width: 0.6),
        columnWidths: {
          0: pw.FixedColumnWidth(34),
          1: pw.FixedColumnWidth(62),
          2: pw.FixedColumnWidth(58),
          3: pw.FlexColumnWidth(1),
        },
        children: [
          pw.TableRow(
            decoration: pw.BoxDecoration(color: hdrBg),
            children: [
              _c('الصف', bold: true),
              _c('يبدأ عند (سم)', bold: true),
              _c('طول الصف', bold: true),
              _c('المحتويات', bold: true),
            ],
          ),
          for (var i = 0; i < rows.length; i++)
            pw.TableRow(children: [
              _c('${i + 1}', bold: true, ltr: true),
              _c(_n(double.parse(rows[i].x.toStringAsFixed(1))), ltr: true),
              _c(_n(double.parse(rows[i].len.toStringAsFixed(1))), ltr: true),
              _c(_rowText(rows[i], c.items),
                  fs: 9, al: pw.Alignment.centerRight),
            ]),
        ],
      ),
      pw.SizedBox(height: 8),
      pw.Text(
          'الصف رقم 1 هو أول صف بيتحمّل (ناحية مقدمة الحاوية)، وآخر صف عند الباب.',
          style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
    ],
  ));

  // ---------- الورقة 2: الرسمة ----------
  doc.addPage(pw.Page(
    pageFormat: PdfPageFormat.a4.landscape,
    margin: const pw.EdgeInsets.all(24),
    textDirection: pw.TextDirection.rtl,
    theme: theme,
    build: (ctx) {
      return pw.Column(
        crossAxisAlignment: pw.CrossAxisAlignment.start,
        children: [
          pw.Row(
            mainAxisAlignment: pw.MainAxisAlignment.spaceBetween,
            children: [
              pw.Text('رسم التحميل - منظر علوي',
                  style: pw.TextStyle(
                      fontSize: 18, fontWeight: pw.FontWeight.bold)),
              pw.Text(
                  '${customer.isEmpty ? '' : '$customer  -  '}${vehicleType}  -  ${c.result.total} جهاز',
                  style: const pw.TextStyle(fontSize: 11)),
            ],
          ),
          pw.SizedBox(height: 10),
          _topViewPdf(c, rows, 794, 330),
          pw.SizedBox(height: 6),
          pw.Text(
              'طول ${_n(c.L)} سم  ×  عرض ${_n(c.W)} سم   |   الطول المستخدم ${_n(double.parse(st.usedLen.toStringAsFixed(1)))} سم   |   المتبقي ${_n(double.parse(rem.toStringAsFixed(1)))} سم',
              style: pw.TextStyle(fontSize: 10, fontWeight: pw.FontWeight.bold)),
          pw.SizedBox(height: 10),
          pw.Wrap(
            spacing: 18,
            runSpacing: 6,
            children: [
              for (var i = 0; i < c.items.length; i++)
                pw.Row(mainAxisSize: pw.MainAxisSize.min, children: [
                  pw.Container(
                      width: 11, height: 11, color: _pc(c.items[i].color)),
                  pw.SizedBox(width: 5),
                  pw.Text(
                      '${c.items[i].name}  (${_n(c.items[i].l)}×${_n(c.items[i].w)}×${_n(c.items[i].h)})  =  ${c.result.loaded[i]} جهاز',
                      style: const pw.TextStyle(fontSize: 10)),
                ]),
            ],
          ),
          pw.SizedBox(height: 10),
          pw.Text(
              'الأرقام فوق الرسم = رقم الصف.  x2 = عمودين أجهزة فوق بعض.  الخط الأحمر = ناحية الباب.',
              style: const pw.TextStyle(fontSize: 9, color: PdfColors.grey700)),
        ],
      );
    },
  ));

  return await doc.save();
}

// ======================= الشاشة =======================

class ItemForm {
  final name = TextEditingController(text: 'بوتاجاز');
  final l = TextEditingController(text: '60');
  final w = TextEditingController(text: '60');
  final h = TextEditingController(text: '85');
  final qty = TextEditingController(text: '0');
  final stack = TextEditingController(text: '2');
  final weight = TextEditingController(text: '');
  void dispose() {
    for (final c in [name, l, w, h, qty, stack, weight]) {
      c.dispose();
    }
  }
}

double _p(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  var t = s.trim().replaceAll('٫', '.').replaceAll(',', '.');
  for (var i = 0; i < 10; i++) {
    t = t.replaceAll(ar[i], '$i');
  }
  return double.tryParse(t) ?? 0;
}

class PlannerPage extends StatefulWidget {
  const PlannerPage({super.key});
  @override
  State<PlannerPage> createState() => _PlannerPageState();
}

class _PlannerPageState extends State<PlannerPage> {
  static const Map<String, List<double>> presets = {
    'حاوية 20 قدم': [590, 235, 239],
    'حاوية 40 قدم': [1203, 235, 239],
    'حاوية 40 قدم هاي كيوب': [1203, 235, 269],
    'عربية نقل 3 طن (تقريبي)': [420, 200, 200],
    'عربية نقل 7 طن (تقريبي)': [600, 240, 240],
    'مقاسات يدوية': [0, 0, 0],
  };

  String preset = 'حاوية 40 قدم';
  final cL = TextEditingController(text: '1203');
  final cW = TextEditingController(text: '235');
  final cH = TextEditingController(text: '239');
  final cPayload = TextEditingController();
  final cCustomer = TextEditingController();
  final cVehicleNo = TextEditingController();
  final List<ItemForm> forms = [ItemForm()];
  Calc? result;
  String? error;
  bool exporting = false;

  @override
  void dispose() {
    for (final c in [cL, cW, cH, cPayload, cCustomer, cVehicleNo]) {
      c.dispose();
    }
    for (final f in forms) {
      f.dispose();
    }
    super.dispose();
  }

  void _calculate() {
    FocusScope.of(context).unfocus();
    final L = _p(cL.text), W = _p(cW.text), H = _p(cH.text);
    if (L <= 0 || W <= 0 || H <= 0) {
      setState(() => error = 'دخّل مقاسات الحاوية أو السيارة صح');
      return;
    }
    final items = <ItemSpec>[];
    for (var i = 0; i < forms.length; i++) {
      final f = forms[i];
      final l = _p(f.l.text), w = _p(f.w.text), h = _p(f.h.text);
      if (l <= 0 || w <= 0 || h <= 0) {
        setState(() => error = 'مقاسات الجهاز رقم ${i + 1} ناقصة');
        return;
      }
      items.add(ItemSpec(
        name: f.name.text.trim().isEmpty ? 'جهاز ${i + 1}' : f.name.text.trim(),
        l: l,
        w: w,
        h: h,
        weight: _p(f.weight.text),
        qty: max(0, _p(f.qty.text).round()),
        maxStack: max(1, _p(f.stack.text).round()),
        color: _colors[i % _colors.length],
      ));
    }
    PackResult? best;
    for (var heur = 0; heur < 3; heur++) {
      for (var rot = 0; rot < 3; rot++) {
        for (var order = 0; order < 2; order++) {
          final r = pack(L, W, H, items, heur, rot, order);
          if (best == null || r.betterThan(best)) best = r;
        }
      }
    }
    setState(() {
      error = null;
      result = Calc(best!, L, W, H, _p(cPayload.text), items);
    });
  }

  Future<void> _exportPdf(Calc c) async {
    setState(() {
      exporting = true;
      error = null;
    });
    try {
      final reg = await PdfGoogleFonts.cairoRegular();
      final bold = await PdfGoogleFonts.cairoBold();
      final bytes = await buildReport(
        c,
        regular: reg,
        bold: bold,
        customer: cCustomer.text.trim(),
        vehicleNo: cVehicleNo.text.trim(),
        vehicleType: preset,
      );
      await Printing.sharePdf(bytes: bytes, filename: 'load_plan.pdf');
    } catch (e) {
      if (mounted) {
        setState(() => error = 'تعذّر إنشاء الـ PDF (لازم إنترنت أول مرة): $e');
      }
    } finally {
      if (mounted) setState(() => exporting = false);
    }
  }

  Widget _field(TextEditingController c, String label) {
    return Expanded(
      child: TextField(
        controller: c,
        keyboardType: const TextInputType.numberWithOptions(decimal: true),
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _textField(TextEditingController c, String label) {
    return Expanded(
      child: TextField(
        controller: c,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
      ),
    );
  }

  Widget _title(String t) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 6),
        child: Text(t,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
      );

  Widget _itemCard(int i) {
    final f = forms[i];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(children: [
          Row(children: [
            Expanded(
              child: TextField(
                controller: f.name,
                decoration: const InputDecoration(
                    labelText: 'اسم الجهاز',
                    isDense: true,
                    border: OutlineInputBorder()),
              ),
            ),
            if (forms.length > 1)
              IconButton(
                icon: const Icon(Icons.delete_outline),
                onPressed: () => setState(() {
                  forms[i].dispose();
                  forms.removeAt(i);
                  result = null;
                }),
              ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _field(f.l, 'الطول'),
            const SizedBox(width: 8),
            _field(f.w, 'العرض'),
            const SizedBox(width: 8),
            _field(f.h, 'الارتفاع'),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _field(f.qty, 'العدد (0 = أقصى كمية)'),
            const SizedBox(width: 8),
            _field(f.stack, 'أقصى طبقات'),
            const SizedBox(width: 8),
            _field(f.weight, 'الوزن كجم'),
          ]),
        ]),
      ),
    );
  }

  Widget _resultView(Calc c) {
    final r = c.result;
    final st = calcStats(c);
    final rem = max(0.0, c.L - st.usedLen);
    final overweight = c.payload > 0 && st.weight > c.payload;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 16),
      Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('إجمالي المحمّل: ${r.total} جهاز',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
                'استغلال الأرضية: ${st.floorPct.toStringAsFixed(0)}%   |   استغلال الحجم: ${st.volPct.toStringAsFixed(0)}%'),
            Text(
                'الطول المستخدم: ${st.usedLen.toStringAsFixed(0)} سم   |   المتبقي: ${rem.toStringAsFixed(0)} سم'),
            if (st.weight > 0)
              Text('الوزن الكلي: ${st.weight.toStringAsFixed(0)} كجم'),
            if (overweight)
              Text(
                  'تنبيه: الوزن أكبر من الحمولة القصوى (${c.payload.toStringAsFixed(0)} كجم)',
                  style: const TextStyle(
                      color: Colors.red, fontWeight: FontWeight.bold)),
            const Divider(),
            for (var i = 0; i < c.items.length; i++)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(children: [
                  Container(width: 14, height: 14, color: c.items[i].color),
                  const SizedBox(width: 8),
                  Expanded(child: Text(_itemLine(c, i))),
                ]),
              ),
          ]),
        ),
      ),
      const SizedBox(height: 10),
      FilledButton.icon(
        onPressed: exporting ? null : () => _exportPdf(c),
        icon: const Icon(Icons.picture_as_pdf),
        label: Text(exporting ? 'جاري التجهيز...' : 'تصدير PDF (ورقتين)'),
      ),
      const SizedBox(height: 12),
      _title('الرسم (منظر علوي)'),
      LayoutBuilder(builder: (ctx, cons) {
        const m = 16.0;
        final scale = max((cons.maxWidth - 2 * m) / c.L, 0.8);
        final cw = c.L * scale + 2 * m;
        final ch = c.W * scale + 2 * m + 22;
        return Card(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: CustomPaint(
              size: Size(cw, ch),
              painter: LoadPainter(c.L, c.W, scale, m, r.placed, c.items),
            ),
          ),
        );
      }),
      const Text('الخط الأحمر = ناحية الباب (آخر حاجة تتحمّل). اسحب الرسم يمين وشمال لو الحاوية طويلة.',
          style: TextStyle(fontSize: 12, color: Colors.black54)),
      const Text('×2 يعني عمودين فوق بعض في نفس المكان.',
          style: TextStyle(fontSize: 12, color: Colors.black54)),
      const SizedBox(height: 24),
    ]);
  }

  String _itemLine(Calc c, int i) {
    final it = c.items[i];
    final got = c.result.loaded[i];
    if (it.h > c.H) return '${it.name}: ارتفاعه أكبر من ارتفاع الحاوية، مش هيدخل';
    if (it.qty == 0) return '${it.name}: $got جهاز';
    final left = it.qty - got;
    return left > 0
        ? '${it.name}: $got من ${it.qty} (فاضل $left مش داخل)'
        : '${it.name}: $got من ${it.qty} (الكل دخل)';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('مخطط تحميل الأجهزة')),
      body: ListView(
        padding: const EdgeInsets.all(12),
        children: [
          _title('بيانات الشحنة (للـ PDF)'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Row(children: [
                _textField(cCustomer, 'اسم العميل'),
                const SizedBox(width: 8),
                _textField(cVehicleNo, 'رقم الحاوية / السيارة'),
              ]),
            ),
          ),
          _title('الحاوية / السيارة (بالسنتيمتر)'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(children: [
                DropdownButton<String>(
                  isExpanded: true,
                  value: preset,
                  items: presets.keys
                      .map((k) => DropdownMenuItem(value: k, child: Text(k)))
                      .toList(),
                  onChanged: (v) {
                    if (v == null) return;
                    setState(() {
                      preset = v;
                      final p = presets[v]!;
                      if (p[0] > 0) {
                        cL.text = p[0].toStringAsFixed(0);
                        cW.text = p[1].toStringAsFixed(0);
                        cH.text = p[2].toStringAsFixed(0);
                      }
                    });
                  },
                ),
                const SizedBox(height: 8),
                Row(children: [
                  _field(cL, 'الطول'),
                  const SizedBox(width: 8),
                  _field(cW, 'العرض'),
                  const SizedBox(width: 8),
                  _field(cH, 'الارتفاع'),
                ]),
                const SizedBox(height: 8),
                Row(children: [_field(cPayload, 'الحمولة القصوى كجم (اختياري)')]),
              ]),
            ),
          ),
          _title('الأجهزة (بالسنتيمتر، مع الكرتونة)'),
          for (var i = 0; i < forms.length; i++) _itemCard(i),
          OutlinedButton.icon(
            onPressed: () => setState(() => forms.add(ItemForm())),
            icon: const Icon(Icons.add),
            label: const Text('إضافة نوع جهاز تاني'),
          ),
          const SizedBox(height: 12),
          FilledButton.icon(
            onPressed: _calculate,
            icon: const Icon(Icons.auto_awesome),
            label: const Text('احسب أفضل ترتيب'),
          ),
          if (error != null)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(error!, style: const TextStyle(color: Colors.red)),
            ),
          if (result != null) _resultView(result!),
        ],
      ),
    );
  }
}

// ======================= الرسم على الشاشة =======================

class LoadPainter extends CustomPainter {
  final double L, W, scale, m;
  final List<Placed> placed;
  final List<ItemSpec> items;
  LoadPainter(this.L, this.W, this.scale, this.m, this.placed, this.items);

  void _text(Canvas canvas, String t, Offset center, double fs, Color color,
      TextDirection dir) {
    final tp = TextPainter(
      text: TextSpan(
          text: t,
          style: TextStyle(
              color: color, fontSize: fs, fontWeight: FontWeight.bold)),
      textDirection: dir,
    )..layout();
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = scale;
    final cont = Rect.fromLTWH(m, m, L * s, W * s);
    canvas.drawRect(cont, Paint()..color = const Color(0xFFEEEEEE));

    for (final p in placed) {
      final r =
          Rect.fromLTWH(m + p.x * s, m + p.y * s, p.w * s, p.h * s).deflate(0.6);
      final col = items[p.item].color;
      canvas.drawRect(r, Paint()..color = col.withAlpha(190));
      canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = Colors.black54);
      if (p.units > 1 && r.width >= 22 && r.height >= 14) {
        _text(canvas, '×${p.units}', r.center, 11, Colors.white,
            TextDirection.ltr);
      }
    }

    canvas.drawRect(
        cont,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2
          ..color = Colors.black87);
    canvas.drawLine(
        cont.topRight,
        cont.bottomRight,
        Paint()
          ..color = Colors.red
          ..strokeWidth = 5);

    _text(
        canvas,
        'الطول ${L.round()} سم × العرض ${W.round()} سم',
        Offset(size.width / 2, m + W * s + 14),
        12,
        Colors.black87,
        TextDirection.rtl);
  }

  @override
  bool shouldRepaint(covariant LoadPainter old) => true;
