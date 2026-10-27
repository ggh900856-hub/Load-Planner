import 'dart:math';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// pose: 0 = تلقائي، 1 = واقف، 2 = نايم على الواجهة/الظهر، 3 = نايم على الجنب
class ItemSpec {
  final String name;
  final String label; // نوع الجهاز اللي بيظهر على الرسمة (مثلاً 60x90)
  final double l, w, h, weight;
  final int qty, maxStack, pose;
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
    this.label = '',
    this.pose = 1,
  });

  ItemSpec withPose(int p) => copy(pose: p);

  ItemSpec copy({int? qty, int? maxStack, int? pose}) => ItemSpec(
        name: name,
        label: label,
        l: l,
        w: w,
        h: h,
        weight: weight,
        qty: qty ?? this.qty,
        maxStack: maxStack ?? this.maxStack,
        color: color,
        pose: pose ?? this.pose,
      );

  // أبعاد الأرضية (fl × fw) والارتفاع الفعلي (fh) حسب الوضع
  double get fl => pose == 2 ? w : l;
  double get fw => pose == 1 ? w : h;
  double get fh => pose == 1 ? h : (pose == 2 ? l : w);

  // اللي بيتكتب على الرسمة
  String get tag => label.isNotEmpty ? label : name;

  String get poseName =>
      pose == 2 ? 'نايم على الواجهة/الظهر' : (pose == 3 ? 'نايم على الجنب' : 'واقف');
  String get poseShort => pose == 2 ? 'نايم ظهر' : (pose == 3 ? 'نايم جنب' : '');
}

class Placed {
  final double x, y, w, h;
  final int item, units;
  Placed(this.x, this.y, this.w, this.h, this.item, this.units);

  Placed copyWith({double? x, double? y, double? w, double? h, int? units}) =>
      Placed(x ?? this.x, y ?? this.y, w ?? this.w, h ?? this.h, item,
          units ?? this.units);
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
  final bool manual;
  final bool edited;
  final List<String> warnings;
  final List<String> notes;
  Calc(this.result, this.L, this.W, this.H, this.payload, this.items,
      {this.manual = false,
      this.edited = false,
      this.warnings = const [],
      this.notes = const []});

  double get usedLen {
    double u = 0;
    for (final p in result.placed) {
      u = max(u, p.x + p.w);
    }
    return u;
  }

  double get usedWid {
    double u = 0;
    for (final p in result.placed) {
      u = max(u, p.y + p.h);
    }
    return u;
  }

  // الزيادة عن طول الحاوية (بالسنتي)
  double get overflow => max(0.0, usedLen - L);

  // عدد الأجهزة اللي خارج الحاوية أو بتعدّي الباب
  int get outside {
    var n = 0;
    for (final p in result.placed) {
      if (p.x + p.w > L + 0.5) n += p.units;
    }
    return n;
  }

  // أرقام الأعمدة المتداخلة مع بعض
  late final Set<int> overlapIdx = _calcOverlap();

  Set<int> _calcOverlap() {
    final s = <int>{};
    final p = result.placed;
    for (var i = 0; i < p.length; i++) {
      for (var j = i + 1; j < p.length; j++) {
        final a = p[i], b = p[j];
        if (a.x < b.x + b.w - 0.5 &&
            b.x < a.x + a.w - 0.5 &&
            a.y < b.y + b.h - 0.5 &&
            b.y < a.y + a.h - 0.5) {
          s.add(i);
          s.add(j);
        }
      }
    }
    return s;
  }
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

/// ترقيم كل عمود بصيغة "صف.عمود" (مثلاً 1.2 = الصف 1 العمود 2)
/// نفس تقسيم الصفوف بتاع buildRows، والأعمدة جوه الصف مترتبة من فوق لتحت.
List<String> numbering(List<Placed> placed) {
  final idx = List<int>.generate(placed.length, (i) => i)
    ..sort((a, b) {
      final d = placed[a].x.compareTo(placed[b].x);
      return d != 0 ? d : placed[a].y.compareTo(placed[b].y);
    });
  final groups = <List<int>>[];
  double gx = 0;
  for (final i in idx) {
    if (groups.isEmpty || (placed[i].x - gx).abs() > 1.0) {
      groups.add([i]);
      gx = placed[i].x;
    } else {
      groups.last.add(i);
    }
  }
  final out = List<String>.filled(placed.length, '');
  for (var r = 0; r < groups.length; r++) {
    final g = groups[r]..sort((a, b) => placed[a].y.compareTo(placed[b].y));
    for (var k = 0; k < g.length; k++) {
      out[g[k]] = '${r + 1}.${k + 1}';
    }
  }
  return out;
}

String _n(double v) =>
    v == v.roundToDouble() ? v.round().toString() : v.toStringAsFixed(1);

String _cm(double v) => _n(double.parse(v.toStringAsFixed(1)));

// نص أرقام/إنجليزي بس (يتكتب شمال ليمين)، أي حاجة فيها عربي تتكتب يمين لشمال
bool _isLtr(String t) => RegExp(r'^[0-9a-zA-Z×x*.\s/\-]+$').hasMatch(t);

// بيوحّد شكل نوع الجهاز: أرقام إنجليزي وعلامة x بدل * و ×
String _normLabel(String s) {
  const ar = '٠١٢٣٤٥٦٧٨٩';
  var t = s.trim();
  for (var i = 0; i < 10; i++) {
    t = t.replaceAll(ar[i], '$i');
  }
  return t.replaceAll(RegExp(r'[*×✕Xx]'), 'x');
}

// ======================= فهم التعليمات المكتوبة =======================

String _normAr(String s) {
  var t = s.toLowerCase();
  const ar = '٠١٢٣٤٥٦٧٨٩';
  for (var i = 0; i < 10; i++) {
    t = t.replaceAll(ar[i], '$i');
  }
  t = t
      .replaceAll(RegExp('[\u064B-\u065F\u0640]'), '')
      .replaceAll(RegExp('[أإآ]'), 'ا')
      .replaceAll('ى', 'ي')
      .replaceAll('ة', 'ه')
      .replaceAll(RegExp('[×*✕]'), 'x')
      .replaceAll(RegExp('[،,;؛:؟?!]'), ' ');
  t = t.replaceAllMapped(
      RegExp(r'(\d)\s*x\s*(\d)'), (m) => '${m[1]}x${m[2]}');
  return t.replaceAll(RegExp(r'\s+'), ' ').trim();
}

class Instr {
  int? qty, layers, across, pose, rot;
  bool get any =>
      qty != null ||
      layers != null ||
      across != null ||
      pose != null ||
      rot != null;
}

// بيدوّر على اسم الجهاز أو نوعه في السطر ويرجّع رقمه والباقي من السطر
(int, String)? _findItem(String line, List<ItemSpec> items) {
  var best = -1, bestLen = 0;
  var rest = line;
  for (var i = 0; i < items.length; i++) {
    for (final raw in [items[i].name, items[i].label]) {
      final k = _normAr(raw);
      if (k.isEmpty || !line.contains(k)) continue;
      if (k.length > bestLen) {
        best = i;
        bestLen = k.length;
        rest = line.replaceFirst(k, ' ');
      }
    }
  }
  return best < 0 ? null : (best, rest);
}

Instr _parseInstr(String s0) {
  var s = ' $s0 ';
  final r = Instr();
  const A = r'[\u0621-\u064A]*';
  RegExpMatch? m;

  // نحذف أي مقاسات زي 50x80 عشان ما تتاخدش كعدد
  s = s.replaceAll(RegExp(r'\d+x\d+(?:x\d+)?'), ' ');

  // الوضع
  m = RegExp('ناي?م$A\\s*(?:علي\\s*)?(?:ال)?جنب$A').firstMatch(s);
  if (m != null) {
    r.pose = 3;
    s = s.replaceFirst(m[0]!, ' ');
  } else {
    m = RegExp('ناي?م$A(?:\\s*علي)?(?:\\s*(?:ال)?(?:ظهر|واجهه|وش|وجه)$A)?')
        .firstMatch(s);
    if (m != null) {
      r.pose = 2;
      s = s.replaceFirst(m[0]!, ' ');
    }
  }
  m = RegExp('واقف$A').firstMatch(s);
  if (m != null) {
    r.pose = 1;
    s = s.replaceFirst(m[0]!, ' ');
  }

  // الاتجاه
  m = RegExp('(?:^|\\s)(?:لف|لفه|مقلوب|عكس)(?:\\s*90)?(?=\\s|\$)')
      .firstMatch(s);
  if (m != null) {
    r.rot = 2;
    s = s.replaceFirst(m[0]!, ' ');
  } else {
    m = RegExp('عادي').firstMatch(s);
    if (m != null) {
      r.rot = 1;
      s = s.replaceFirst(m[0]!, ' ');
    }
  }

  // الأدوار
  const lay = '(?:ادوار|طبقات|طبقه|طوابق|فوق بعض|دور)';
  m = RegExp('(\\d+)\\s*$lay').firstMatch(s) ??
      RegExp('$lay\\s*(\\d+)').firstMatch(s);
  if (m != null) {
    r.layers = int.tryParse(m[1]!);
    s = s.replaceFirst(m[0]!, ' ');
  }

  // جنب بعض في العرض
  const acr = '(?:جنب بعض|جنب|في العرض|بالعرض|عمود|عواميد)';
  m = RegExp('(\\d+)\\s*$acr').firstMatch(s) ??
      RegExp('$acr\\s*(\\d+)').firstMatch(s);
  if (m != null) {
    r.across = int.tryParse(m[1]!);
    s = s.replaceFirst(m[0]!, ' ');
  }

  // العدد
  m = RegExp(
              '(\\d+)\\s*(?:جهاز|اجهزه|قطعه|قطع|وحده|وحدات|حته|حتت|كرتونه|كراتين|ماكينه|عدد)')
          .firstMatch(s) ??
      RegExp('عدد\\s*(\\d+)').firstMatch(s);
  if (m != null) {
    r.qty = int.tryParse(m[1]!);
    s = s.replaceFirst(m[0]!, ' ');
  }
  if (r.qty == null) {
    m = RegExp(r'(\d+)').firstMatch(s);
    if (m != null) r.qty = int.tryParse(m[1]!);
  }
  return r;
}

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
        ? items[a].fl * items[a].fw
        : max(items[a].fl, items[a].fw);
    final y = order == 0
        ? items[b].fl * items[b].fw
        : max(items[b].fl, items[b].fw);
    return y.compareTo(x);
  });
  final placed = <Placed>[];
  final loaded = List<int>.filled(items.length, 0);
  for (final i in idx) {
    final it = items[i];
    final k = min(it.maxStack, (H / it.fh + 1e-9).floor());
    if (k < 1) continue;
    var remaining = it.qty <= 0 ? (1 << 30) : it.qty;
    while (remaining > 0) {
      final r = bin.insert(it.fl, it.fw, rotMode, heur);
      if (r == null) break;
      final u = min(k, remaining);
      placed.add(Placed(r.x, r.y, r.w, r.h, i, u));
      loaded[i] += u;
      remaining -= u;
    }
  }
  return PackResult(placed, loaded);
}

/// الترتيب اليدوي (بتعليمات المستخدم): كل نوع في صفوف، بالترتيب من المقدمة للباب.
/// مفيش حد للطول، لو زاد عن الحاوية بيتحسب ويتعرض كزيادة.
(PackResult, List<String>) packManual(double W, double H,
    List<ItemSpec> items, List<int> across, List<int> rot) {
  final placed = <Placed>[];
  final loaded = List<int>.filled(items.length, 0);
  final warns = <String>[];
  double x = 0;
  for (var i = 0; i < items.length; i++) {
    final it = items[i];
    final rl = rot[i] == 2 ? it.fw : it.fl; // على طول الحاوية
    final rw = rot[i] == 2 ? it.fl : it.fw; // على عرض الحاوية
    final cols = (it.qty / it.maxStack).ceil();
    var per = across[i] > 0 ? across[i] : (W / rw + 1e-9).floor();
    if (per < 1) per = 1;
    per = min(per, cols);

    if (per * rw > W + 0.5) {
      warns.add(
          '${it.tag}: $per جهاز جنب بعض عرضهم ${_cm(per * rw)} سم، أكبر من عرض الحاوية بـ ${_cm(per * rw - W)} سم');
    }
    final need = min(it.maxStack, it.qty) * it.fh;
    if (need > H + 0.5) {
      warns.add(
          '${it.tag}: ارتفاعه ${_cm(need)} سم، أكبر من ارتفاع الحاوية بـ ${_cm(need - H)} سم');
    }

    var remaining = it.qty;
    var col = 0;
    while (remaining > 0) {
      final u = min(it.maxStack, remaining);
      placed.add(Placed(x, col * rw, rl, rw, i, u));
      loaded[i] += u;
      remaining -= u;
      col++;
      if (col == per) {
        col = 0;
        x += rl;
      }
    }
    if (col != 0) x += rl;
  }
  return (PackResult(placed, loaded), warns);
}

// ======================= تقرير PDF (بيترسم زي الشاشة) =======================

const double _pageW = 595.28, _pageH = 841.89;

class _Cell {
  final String t;
  final bool bold;
  final Color? bg;
  final double fs;
  final Color color;
  final TextAlign align;
  const _Cell(this.t,
      {this.bold = false,
      this.bg,
      this.fs = 10,
      this.color = Colors.black,
      this.align = TextAlign.center});
}

TextPainter _rtp(
    String t, double fs, Color col, bool bold, double w, TextAlign al) {
  return TextPainter(
    text: TextSpan(
        text: t,
        style: TextStyle(
            color: col,
            fontSize: fs,
            height: 1.25,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
    textDirection: _isLtr(t) ? TextDirection.ltr : TextDirection.rtl,
    textAlign: al,
  )..layout(minWidth: w, maxWidth: w);
}

TextPainter _ntp(String t, double fs, Color col, bool bold) {
  return TextPainter(
    text: TextSpan(
        text: t,
        style: TextStyle(
            color: col,
            fontSize: fs,
            fontWeight: bold ? FontWeight.bold : FontWeight.normal)),
    textDirection: _isLtr(t) ? TextDirection.ltr : TextDirection.rtl,
  )..layout();
}

class _Pager {
  final double w, h, margin, ratio;
  final List<ui.Picture> _done = [];
  late ui.PictureRecorder _rec;
  late Canvas canvas;
  double y = 0;

  _Pager(this.w, this.h, {this.margin = 28, this.ratio = 3}) {
    _start();
  }

  double get cw => w - 2 * margin;
  double get left => margin;
  double get right => w - margin;

  void _start() {
    _rec = ui.PictureRecorder();
    canvas = Canvas(_rec);
    canvas.scale(ratio);
    canvas.drawRect(Rect.fromLTWH(0, 0, w, h), Paint()..color = Colors.white);
    y = margin;
  }

  void ensure(double need) {
    if (y + need > h - margin && y > margin + 1) {
      _done.add(_rec.endRecording());
      _start();
    }
  }

  void gap(double d) => y += d;

  void para(String t,
      {double fs = 10,
      Color color = Colors.black,
      bool bold = false,
      TextAlign align = TextAlign.start}) {
    final tp = _rtp(t, fs, color, bold, cw, align);
    ensure(tp.height + 2);
    tp.paint(canvas, Offset(left, y));
    y += tp.height + 2;
  }

  // الجدول بيتكتب من اليمين لليسار (أول عمود على اليمين)
  void table(List<double> flex, List<List<_Cell>> rows) {
    final sum = flex.fold(0.0, (a, b) => a + b);
    final widths = [for (final f in flex) f / sum * cw];
    for (final cells in rows) {
      final tps = <TextPainter>[];
      var rh = 0.0;
      for (var i = 0; i < cells.length; i++) {
        final c = cells[i];
        final tp =
            _rtp(c.t, c.fs, c.color, c.bold, widths[i] - 8, c.align);
        tps.add(tp);
        rh = max(rh, tp.height + 8);
      }
      ensure(rh);
      var x = right;
      for (var i = 0; i < cells.length; i++) {
        x -= widths[i];
        final rect = Rect.fromLTWH(x, y, widths[i], rh);
        final bg = cells[i].bg;
        if (bg != null) canvas.drawRect(rect, Paint()..color = bg);
        canvas.drawRect(
            rect,
            Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 0.6
              ..color = const Color(0xFF757575));
        tps[i].paint(canvas, Offset(x + 4, y + (rh - tps[i].height) / 2));
      }
      y += rh;
    }
  }

  Future<List<Uint8List>> finish() async {
    _done.add(_rec.endRecording());
    final out = <Uint8List>[];
    for (final p in _done) {
      final img = await p.toImage((w * ratio).round(), (h * ratio).round());
      final bd = await img.toByteData(format: ui.ImageByteFormat.png);
      out.add(bd!.buffer.asUint8List());
    }
    return out;
  }
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
    final pose = it.poseShort.isEmpty ? '' : ' (${it.poseShort})';
    parts.add('${it.tag}$pose: $u جهاز ($st عمود)');
  });
  return parts.join('   |   ');
}

Future<Uint8List> buildReport(Calc c,
    {required String customer,
    required String vehicleNo,
    required String vehicleType}) async {
  final st = calcStats(c);
  final rows = buildRows(c.result.placed);
  final rem = max(0.0, c.L - st.usedLen);
  final over = c.overflow;
  final overweight = c.payload > 0 && st.weight > c.payload;
  const lblBg = Color(0xFFEEEEEE);
  const hdrBg = Color(0xFFE0E0E0);
  const red = Color(0xFFC62828);

  _Cell lc(String t) => _Cell(t, bold: true, bg: lblBg);
  _Cell vc(String t, {bool bold = false}) => _Cell(t, bold: bold);
  _Cell hc(String t) => _Cell(t, bold: true, bg: hdrBg, fs: 9.5);

  // ---------- الورقة 1: التفاصيل ----------
  final g1 = _Pager(_pageW, _pageH);
  g1.para('بيان تحميل', fs: 22, bold: true, align: TextAlign.center);
  g1.gap(8);
  g1.table([
    1.4,
    2,
    1.4,
    2
  ], [
    [
      lc('العميل'),
      vc(customer.isEmpty ? '-' : customer),
      lc('التاريخ'),
      vc(_dateNow())
    ],
    [
      lc('رقم الحاوية / السيارة'),
      vc(vehicleNo.isEmpty ? '-' : vehicleNo),
      lc('النوع'),
      vc(vehicleType)
    ],
    [
      lc('مقاسات الحاوية (سم)'),
      vc('${_n(c.L)} x ${_n(c.W)} x ${_n(c.H)}'),
      lc('إجمالي الأجهزة'),
      vc('${c.result.total} جهاز', bold: true)
    ],
    [
      lc('الطول المستخدم (سم)'),
      vc(_cm(st.usedLen)),
      lc(over > 0.5 ? 'الزيادة عن الحاوية (سم)' : 'الطول المتبقي (سم)'),
      vc(over > 0.5 ? _cm(over) : _cm(rem), bold: true)
    ],
    [
      lc('استغلال الأرضية'),
      vc('${st.floorPct.toStringAsFixed(0)}%'),
      lc('استغلال الحجم'),
      vc('${st.volPct.toStringAsFixed(0)}%')
    ],
    [
      lc('الوزن الكلي (كجم)'),
      vc(st.weight > 0 ? st.weight.toStringAsFixed(0) : '-'),
      lc('الحمولة القصوى (كجم)'),
      vc(c.payload > 0 ? c.payload.toStringAsFixed(0) : '-')
    ],
  ]);

  if (over > 0.5) {
    g1.gap(6);
    g1.para(
        'تنبيه: الحمولة أطول من الحاوية بمقدار ${_cm(over)} سم (${c.outside} جهاز خارج الحاوية).',
        fs: 11,
        bold: true,
        color: red);
  }
  if (c.overlapIdx.isNotEmpty) {
    g1.para('تنبيه: في ${c.overlapIdx.length} عمود متداخلين مع بعض في الرسمة.',
        fs: 11, bold: true, color: red);
  }
  for (final w in c.warnings) {
    g1.para('تنبيه: $w', fs: 10, bold: true, color: red);
  }
  if (overweight) {
    g1.para('تنبيه: الوزن الكلي أكبر من الحمولة القصوى!',
        fs: 11, bold: true, color: red);
  }

  g1.gap(12);
  g1.para('ملخص الأنواع', fs: 13, bold: true);
  g1.gap(2);
  g1.table([
    0.6,
    2,
    2.2,
    1.9,
    1.3,
    1.3,
    1.2,
    1.1,
    1.4
  ], [
    [
      hc('م'),
      hc('الصنف'),
      hc('المقاس (سم)'),
      hc('الوضع'),
      hc('المطلوب'),
      hc('المحمّل'),
      hc('الباقي'),
      hc('الأدوار'),
      hc('الوزن (كجم)'),
    ],
    for (var i = 0; i < c.items.length; i++)
      [
        vc('${i + 1}'),
        vc(c.items[i].label.isEmpty
            ? c.items[i].name
            : '${c.items[i].name} (${c.items[i].label})'),
        vc('${_n(c.items[i].l)}x${_n(c.items[i].w)}x${_n(c.items[i].h)}'),
        _Cell(c.items[i].poseName, fs: 8.5),
        vc(c.items[i].qty == 0 ? 'أقصى كمية' : '${c.items[i].qty}'),
        vc('${c.result.loaded[i]}', bold: true),
        vc(c.items[i].qty == 0
            ? '-'
            : '${max(0, c.items[i].qty - c.result.loaded[i])}'),
        vc('${c.items[i].maxStack}'),
        vc(c.items[i].weight > 0
            ? (c.result.loaded[i] * c.items[i].weight).toStringAsFixed(0)
            : '-'),
      ],
  ]);

  g1.gap(12);
  g1.para('تفاصيل الصفوف (بالترتيب اللي بيتحمّل بيه)', fs: 13, bold: true);
  g1.gap(2);
  g1.table([
    34,
    62,
    58,
    385
  ], [
    [hc('الصف'), hc('يبدأ عند (سم)'), hc('طول الصف'), hc('المحتويات')],
    for (var i = 0; i < rows.length; i++)
      [
        _Cell('${i + 1}', bold: true),
        vc(_cm(rows[i].x)),
        vc(_cm(rows[i].len)),
        _Cell(_rowText(rows[i], c.items), fs: 9, align: TextAlign.start),
      ],
  ]);
  g1.gap(8);
  g1.para(
      'الصف رقم 1 هو أول صف بيتحمّل (ناحية مقدمة الحاوية)، وآخر صف عند الباب.',
      fs: 9,
      color: const Color(0xFF616161));

  // ---------- الورقة 2: الرسمة (أفقي) ----------
  final g2 = _Pager(_pageH, _pageW, margin: 24);
  final t1 = _rtp('رسم التحميل - منظر علوي', 18, Colors.black, true, g2.cw,
      TextAlign.start);
  t1.paint(g2.canvas, Offset(g2.left, g2.y));
  final sub =
      '${customer.isEmpty ? '' : '$customer  -  '}$vehicleType  -  ${c.result.total} جهاز';
  final t2 = _rtp(sub, 11, Colors.black, false, g2.cw, TextAlign.end);
  t2.paint(g2.canvas, Offset(g2.left, g2.y + 5));
  g2.y += t1.height + 8;

  const m = 16.0;
  final totL = max(c.L, c.usedLen);
  final totW = max(c.W, c.usedWid);
  final availH = g2.h - g2.margin - g2.y - 100;
  final scale = max(
      0.05,
      min((g2.cw - 2 * m) / totL,
          (availH - LoadPainter.topPad - LoadPainter.bottomPad) / totW));
  final dw = totL * scale + 2 * m;
  final dh = LoadPainter.topPad + totW * scale + LoadPainter.bottomPad;
  g2.canvas.save();
  g2.canvas.translate(g2.left, g2.y);
  LoadPainter(c.L, c.W, scale, m, c.result.placed, c.items,
          overlap: c.overlapIdx, showNums: true)
      .paint(g2.canvas, Size(dw, dh));
  g2.canvas.restore();
  g2.y += dh + 6;

  g2.para(
      'الطول ${_n(c.L)} سم  -  العرض ${_n(c.W)} سم   |   الطول المستخدم ${_cm(st.usedLen)} سم   |   ${over > 0.5 ? 'زيادة عن الحاوية ${_cm(over)} سم' : 'المتبقي ${_cm(rem)} سم'}',
      fs: 10,
      bold: true,
      color: over > 0.5 ? red : Colors.black);
  g2.gap(4);

  // دليل الألوان
  var lx = g2.right;
  var ly = g2.y;
  for (var i = 0; i < c.items.length; i++) {
    final it = c.items[i];
    final text =
        '${it.tag}${it.poseShort.isEmpty ? '' : ' (${it.poseShort})'}  =  ${c.result.loaded[i]} جهاز';
    final tp = _ntp(text, 10, Colors.black, false);
    final need = 11 + 5 + tp.width + 18;
    if (lx - need < g2.left && lx != g2.right) {
      lx = g2.right;
      ly += 18;
    }
    g2.canvas.drawRect(
        Rect.fromLTWH(lx - 11, ly + 2, 11, 11), Paint()..color = it.color);
    tp.paint(g2.canvas, Offset(lx - 11 - 5 - tp.width, ly));
    lx -= need;
  }
  g2.y = ly + 22;
  g2.para(
      'الأرقام فوق الرسم = رقم الصف.  الرقم الصغير على كل جهاز = صف.عمود (مثلاً 1.2 = الصف 1 العمود 2).  المكتوب على الجهاز = نوعه وتحته عدد الأدوار.  الخط الأحمر = ناحية الباب.  الأحمر على الجهاز = خارج الحاوية أو متداخل.',
      fs: 9,
      color: const Color(0xFF616161));

  // ---------- تجميع الـ PDF ----------
  final imgs1 = await g1.finish();
  final imgs2 = await g2.finish();
  final doc = pw.Document();
  for (final b in imgs1) {
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4,
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.FullPage(
        ignoreMargins: true,
        child: pw.Image(pw.MemoryImage(b), fit: pw.BoxFit.fill),
      ),
    ));
  }
  for (final b in imgs2) {
    doc.addPage(pw.Page(
      pageFormat: PdfPageFormat.a4.landscape,
      margin: pw.EdgeInsets.zero,
      build: (_) => pw.FullPage(
        ignoreMargins: true,
        child: pw.Image(pw.MemoryImage(b), fit: pw.BoxFit.fill),
      ),
    ));
  }
  return await doc.save();
}

// ======================= الشاشة =======================

class ItemForm {
  final name = TextEditingController(text: 'بوتاجاز');
  final label = TextEditingController(text: '');
  final l = TextEditingController(text: '60');
  final w = TextEditingController(text: '60');
  final h = TextEditingController(text: '85');
  final qty = TextEditingController(text: '0');
  final stack = TextEditingController(text: '2');
  final weight = TextEditingController(text: '');
  final across = TextEditingController(text: '0');
  int pose = 1; // 0 تلقائي، 1 واقف، 2 نايم واجهة/ظهر، 3 نايم جنب
  int rot = 1; // 1 عادي، 2 لف 90° (للترتيب اليدوي)
  void dispose() {
    for (final c in [name, label, l, w, h, qty, stack, weight, across]) {
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
  final cInstr = TextEditingController();
  final List<ItemForm> forms = [ItemForm()];
  Calc? result;
  String? error;
  bool exporting = false;
  double zoom = 1.0;
  bool showNums = true;

  // وضع التعديل بإيدك
  bool editMode = false;
  bool snap = true;
  int? sel; // رقم العمود المختار
  int? _drag; // رقم العمود اللي بيتسحب
  Offset _grab = Offset.zero; // مكان الإمساك جوه الجهاز (سم)
  Offset _dtPos = Offset.zero; // مكان الضغطة المزدوجة
  int _step = 5;
  final List<List<Placed>> _undo = [];

  @override
  void dispose() {
    for (final c in [cL, cW, cH, cPayload, cCustomer, cVehicleNo, cInstr]) {
      c.dispose();
    }
    for (final f in forms) {
      f.dispose();
    }
    super.dispose();
  }

  void _resetEdit() {
    _undo.clear();
    sel = null;
    _drag = null;
  }

  // بيقرا المدخلات ويتأكد منها
  ({double L, double W, double H, List<ItemSpec> items})? _readInputs() {
    final L = _p(cL.text), W = _p(cW.text), H = _p(cH.text);
    if (L <= 0 || W <= 0 || H <= 0) {
      setState(() => error = 'دخّل مقاسات الحاوية أو السيارة صح');
      return null;
    }
    final items = <ItemSpec>[];
    for (var i = 0; i < forms.length; i++) {
      final f = forms[i];
      final l = _p(f.l.text), w = _p(f.w.text), h = _p(f.h.text);
      if (l <= 0 || w <= 0 || h <= 0) {
        setState(() => error = 'مقاسات الجهاز رقم ${i + 1} ناقصة');
        return null;
      }
      items.add(ItemSpec(
        name: f.name.text.trim().isEmpty ? 'جهاز ${i + 1}' : f.name.text.trim(),
        label: _normLabel(f.label.text),
        l: l,
        w: w,
        h: h,
        weight: _p(f.weight.text),
        qty: max(0, _p(f.qty.text).round()),
        maxStack: max(1, _p(f.stack.text).round()),
        color: _colors[i % _colors.length],
        pose: f.pose,
      ));
    }
    return (L: L, W: W, H: H, items: items);
  }

  // الترتيب التلقائي (أفضل ترتيب)
  void _calculate() {
    FocusScope.of(context).unfocus();
    final inp = _readInputs();
    if (inp == null) return;
    final L = inp.L, W = inp.W, H = inp.H, items = inp.items;

    // لو فيه أصناف "تلقائي" بنجرب كل وضع (واقف / نايم ظهر / نايم جنب)
    final variants = <List<ItemSpec>>[];
    if (items.any((e) => e.pose == 0)) {
      for (var p = 1; p <= 3; p++) {
        variants.add([for (final e in items) e.pose == 0 ? e.withPose(p) : e]);
      }
    } else {
      variants.add(items);
    }

    PackResult? best;
    List<ItemSpec> bestItems = items;
    for (final v in variants) {
      for (var heur = 0; heur < 3; heur++) {
        for (var rot = 0; rot < 3; rot++) {
          for (var order = 0; order < 2; order++) {
            final r = pack(L, W, H, v, heur, rot, order);
            if (best == null || r.betterThan(best)) {
              best = r;
              bestItems = v;
            }
          }
        }
      }
    }
    final finalBest = best!;
    final finalItems = bestItems;
    setState(() {
      error = null;
      _resetEdit();
      result = Calc(finalBest, L, W, H, _p(cPayload.text), finalItems);
    });
  }

  // الترتيب اليدوي: الخانات + التعليمات المكتوبة
  void _calculateManual() {
    FocusScope.of(context).unfocus();
    final inp = _readInputs();
    if (inp == null) return;
    final base = inp.items;
    final n = base.length;

    final qty = [for (final e in base) e.qty];
    final lay = [for (final e in base) e.maxStack];
    final across = [for (final f in forms) max(0, _p(f.across.text).round())];
    final rot = [for (final f in forms) f.rot];
    final pose = [for (final e in base) e.pose == 0 ? 1 : e.pose];
    final warns = <String>[];
    final mentioned = <int>[];

    final lines = cInstr.text
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty);
    for (final raw in lines) {
      final ln = _normAr(raw);
      var found = _findItem(ln, base);
      if (found == null && n == 1) found = (0, ln);
      if (found == null) {
        warns.add('مش فاهم السطر "$raw" (ابدأه باسم الجهاز أو نوعه)');
        continue;
      }
      final (idx, rest) = found;
      final ins = _parseInstr(rest);
      if (!ins.any) {
        warns.add('السطر "$raw": مفهمتش منه أي تعليمات');
        continue;
      }
      if (ins.qty != null) qty[idx] = ins.qty!;
      if (ins.layers != null) lay[idx] = ins.layers!;
      if (ins.across != null) across[idx] = ins.across!;
      if (ins.pose != null) pose[idx] = ins.pose!;
      if (ins.rot != null) rot[idx] = ins.rot!;
      if (!mentioned.contains(idx)) mentioned.add(idx);
    }

    // الأجهزة اللي في التعليمات الأول بترتيب السطور، وبعدها الباقي
    final order = [
      ...mentioned,
      for (var i = 0; i < n; i++)
        if (!mentioned.contains(i)) i
    ];

    final items = <ItemSpec>[];
    final acr = <int>[];
    final rt = <int>[];
    for (final i in order) {
      if (qty[i] <= 0) {
        warns.add('${base[i].tag}: العدد 0 فتجاهلته (اكتب العدد)');
        continue;
      }
      items.add(
          base[i].copy(qty: qty[i], maxStack: max(1, lay[i]), pose: pose[i]));
      acr.add(across[i]);
      rt.add(rot[i]);
    }
    if (items.isEmpty) {
      setState(() => error = 'اكتب عدد الأجهزة (في الخانة أو في التعليمات)');
      return;
    }

    final (r, w2) = packManual(inp.W, inp.H, items, acr, rt);

    final notes = <String>[];
    for (var k = 0; k < items.length; k++) {
      final it = items[k];
      final parts = <String>[
        '${it.qty} جهاز',
        acr[k] > 0 ? '${acr[k]} جنب بعض' : 'جنب بعض تلقائي',
        '${it.maxStack} أدوار',
      ];
      if (it.pose != 1) parts.add(it.poseShort);
      if (rt[k] == 2) parts.add('ملفوف 90°');
      notes.add('${k + 1}. ${it.tag}: ${parts.join('، ')}');
    }

    setState(() {
      error = null;
      _resetEdit();
      result = Calc(r, inp.L, inp.W, inp.H, _p(cPayload.text), items,
          manual: true, warnings: [...warns, ...w2], notes: notes);
    });
  }

  // حاوية فاضية: ترسم فيها بإيدك من الصفر
  void _startBlank() {
    FocusScope.of(context).unfocus();
    final inp = _readInputs();
    if (inp == null) return;
    final items = [for (final e in inp.items) e.pose == 0 ? e.withPose(1) : e];
    setState(() {
      error = null;
      _resetEdit();
      editMode = true;
      result = Calc(PackResult([], List<int>.filled(items.length, 0)), inp.L,
          inp.W, inp.H, _p(cPayload.text), items,
          manual: true,
          edited: true,
          notes: const [
            'حاوية فاضية: اضغط "إضافة عمود" واختار الجهاز، وبعدها حرّكه بإيدك'
          ]);
    });
  }

  // ---------- التعديل بإيدك ----------

  void _pushUndo() {
    _undo.add(result!.result.placed);
    if (_undo.length > 60) _undo.removeAt(0);
  }

  // بيبني النتيجة من جديد بعد أي تعديل (لازم يتنادى جوه setState)
  void _applyPlaced(List<Placed> np) {
    final c = result!;
    final loaded = List<int>.filled(c.items.length, 0);
    for (final p in np) {
      loaded[p.item] += p.units;
    }
    result = Calc(PackResult(np, loaded), c.L, c.W, c.H, c.payload, c.items,
        manual: c.manual,
        edited: true,
        warnings: const [],
        notes: const ['الترتيب معدّل بإيدك']);
  }

  int? _hit(Offset pos, double scale, double m) {
    final x = (pos.dx - m) / scale, y = (pos.dy - LoadPainter.topPad) / scale;
    final pl = result!.result.placed;
    for (var i = pl.length - 1; i >= 0; i--) {
      final p = pl[i];
      if (x >= p.x && x <= p.x + p.w && y >= p.y && y <= p.y + p.h) return i;
    }
    return null;
  }

  void _moveTo(int i, double nx, double ny, double scale) {
    final c = result!;
    final pl = c.result.placed;
    final p = pl[i];
    var x = max(0.0, nx), y = max(0.0, ny);
    if (snap) {
      final th = 8 / scale; // 8 بكسل
      var bestDx = th + 1, bestDy = th + 1;
      var sx = x, sy = y;
      final cx = x, cy = y;
      void tryX(double cand) {
        final d = (cand - cx).abs();
        if (d <= th && d < bestDx) {
          bestDx = d;
          sx = cand;
        }
      }

      void tryY(double cand) {
        final d = (cand - cy).abs();
        if (d <= th && d < bestDy) {
          bestDy = d;
          sy = cand;
        }
      }

      tryX(0);
      tryX(c.L - p.w);
      tryY(0);
      tryY(c.W - p.h);
      for (var j = 0; j < pl.length; j++) {
        if (j == i) continue;
        final q = pl[j];
        tryX(q.x + q.w);
        tryX(q.x - p.w);
        tryX(q.x);
        tryY(q.y + q.h);
        tryY(q.y - p.h);
        tryY(q.y);
      }
      x = max(0.0, sx);
      y = max(0.0, sy);
    }
    final np = [...pl];
    np[i] = p.copyWith(x: x, y: y);
    _applyPlaced(np);
  }

  void _nudge(double dx, double dy) {
    final i = sel;
    if (i == null) return;
    final pl = result!.result.placed;
    if (i >= pl.length) return;
    setState(() {
      _pushUndo();
      final p = pl[i];
      final np = [...pl];
      np[i] = p.copyWith(
          x: max(0.0, p.x + dx * _step), y: max(0.0, p.y + dy * _step));
      _applyPlaced(np);
    });
  }

  // لف 90 درجة (بيبدّل الطول مع العرض في الرسمة) - لازم جوه setState
  void _rotateIdx(int i) {
    final pl = result!.result.placed;
    if (i < 0 || i >= pl.length) return;
    _pushUndo();
    final p = pl[i];
    final np = [...pl];
    np[i] = p.copyWith(w: p.h, h: p.w);
    _applyPlaced(np);
  }

  void _rotateSel() {
    final i = sel;
    if (i == null) return;
    setState(() => _rotateIdx(i));
  }

  void _setUnits(int d) {
    final i = sel;
    if (i == null) return;
    final c = result!;
    final pl = c.result.placed;
    if (i >= pl.length) return;
    final p = pl[i];
    final it = c.items[p.item];
    final mx = max(1, (c.H / it.fh + 1e-9).floor());
    final nu = min(mx, max(1, p.units + d));
    if (nu == p.units) return;
    setState(() {
      _pushUndo();
      final np = [...pl];
      np[i] = p.copyWith(units: nu);
      _applyPlaced(np);
    });
  }

  void _copySel() {
    final i = sel;
    if (i == null) return;
    final c = result!;
    final pl = c.result.placed;
    if (i >= pl.length) return;
    setState(() {
      _pushUndo();
      final p = pl[i];
      final spot = _freeSpot(c, p.w, p.h);
      final np = [...pl, p.copyWith(x: spot.dx, y: spot.dy)];
      _applyPlaced(np);
      sel = np.length - 1;
    });
  }

  void _deleteSel() {
    final i = sel;
    if (i == null) return;
    final pl = result!.result.placed;
    if (i >= pl.length) return;
    setState(() {
      _pushUndo();
      final np = [...pl]..removeAt(i);
      _applyPlaced(np);
      sel = null;
    });
  }

  // فضّي الحاوية بالكامل
  void _clearAll() {
    final c = result;
    if (c == null || c.result.placed.isEmpty) return;
    setState(() {
      _pushUndo();
      _applyPlaced(<Placed>[]);
      sel = null;
    });
  }

  // أول مكان فاضي جوه الحاوية (من المقدمة، وبعدين العرض)
  Offset _freeSpot(Calc c, double w, double h) {
    final pl = c.result.placed;
    final cands = <Offset>[const Offset(0, 0)];
    for (final p in pl) {
      cands.add(Offset(p.x + p.w, p.y));
      cands.add(Offset(p.x, p.y + p.h));
      cands.add(Offset(p.x + p.w, 0));
    }
    cands.sort((a, b) {
      final d = a.dx.compareTo(b.dx);
      return d != 0 ? d : a.dy.compareTo(b.dy);
    });
    for (final insideOnly in [true, false]) {
      for (final o in cands) {
        if (o.dy + h > c.W + 0.5) continue;
        if (insideOnly && o.dx + w > c.L + 0.5) continue;
        var ok = true;
        for (final p in pl) {
          if (o.dx < p.x + p.w - 0.5 &&
              p.x < o.dx + w - 0.5 &&
              o.dy < p.y + p.h - 0.5 &&
              p.y < o.dy + h - 0.5) {
            ok = false;
            break;
          }
        }
        if (ok) return o;
      }
    }
    return Offset(c.usedLen, 0);
  }

  void _addColumn(int i) {
    final c = result!;
    final it = c.items[i];
    final k = max(1, min(it.maxStack, (c.H / it.fh + 1e-9).floor()));
    setState(() {
      _pushUndo();
      final spot = _freeSpot(c, it.fl, it.fw);
      final np = [
        ...c.result.placed,
        Placed(spot.dx, spot.dy, it.fl, it.fw, i, k)
      ];
      _applyPlaced(np);
      sel = np.length - 1;
    });
  }

  void _undoOnce() {
    if (_undo.isEmpty) return;
    setState(() {
      final prev = _undo.removeLast();
      _applyPlaced(prev);
      sel = null;
    });
  }

  Future<void> _exportPdf(Calc c) async {
    setState(() {
      exporting = true;
      error = null;
    });
    try {
      final bytes = await buildReport(
        c,
        customer: cCustomer.text.trim(),
        vehicleNo: cVehicleNo.text.trim(),
        vehicleType: preset,
      );
      await Printing.sharePdf(bytes: bytes, filename: 'load_plan.pdf');
    } catch (e) {
      if (mounted) {
        setState(() => error = 'تعذّر إنشاء الـ PDF: $e');
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
                  _resetEdit();
                }),
              ),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            _textField(f.label, 'نوع الجهاز (يظهر على الرسمة) مثال: 60x90'),
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
            _field(f.stack, 'عدد الأدوار (فوق بعض)'),
            const SizedBox(width: 8),
            _field(f.qty, 'العدد (0 = أقصى كمية)'),
            const SizedBox(width: 8),
            _field(f.weight, 'الوزن كجم'),
          ]),
          const SizedBox(height: 8),
          Row(children: [
            const Text('وضع الجهاز:  '),
            Expanded(
              child: DropdownButton<int>(
                isExpanded: true,
                value: f.pose,
                items: const [
                  DropdownMenuItem(value: 1, child: Text('واقف (عادي)')),
                  DropdownMenuItem(
                      value: 2, child: Text('نايم على الواجهة / الظهر')),
                  DropdownMenuItem(value: 3, child: Text('نايم على الجنب')),
                  DropdownMenuItem(
                      value: 0, child: Text('تلقائي (يجرب كل الأوضاع)')),
                ],
                onChanged: (v) => setState(() => f.pose = v ?? 1),
              ),
            ),
          ]),
          const Divider(),
          const Align(
            alignment: Alignment.centerRight,
            child: Text('تعليماتك (للزر "جرّب ترتيبي" بس)',
                style: TextStyle(fontWeight: FontWeight.bold)),
          ),
          const SizedBox(height: 8),
          Row(children: [
            _field(f.across, 'عدد جنب بعض في العرض (0 = تلقائي)'),
          ]),
          const SizedBox(height: 4),
          Row(children: [
            const Text('اتجاه الجهاز:  '),
            Expanded(
              child: DropdownButton<int>(
                isExpanded: true,
                value: f.rot,
                items: const [
                  DropdownMenuItem(
                      value: 1, child: Text('عادي (الطول على طول الحاوية)')),
                  DropdownMenuItem(
                      value: 2, child: Text('لف 90° (العرض على طول الحاوية)')),
                ],
                onChanged: (v) => setState(() => f.rot = v ?? 1),
              ),
            ),
          ]),
        ]),
      ),
    );
  }

  // شريط أدوات التعديل بإيدك
  Widget _editBar(Calc c) {
    final pl = c.result.placed;
    final p = (sel != null && sel! < pl.length) ? pl[sel!] : null;
    final it = p == null ? null : c.items[p.item];
    final has = p != null;
    final num = has ? numbering(pl)[sel!] : '';

    return Card(
      color: Colors.amber.shade50,
      child: Padding(
        padding: const EdgeInsets.all(10),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(
            has
                ? 'المختار $num: ${it!.tag} | ${_cm(p.w)}x${_cm(p.h)} سم | ${_cm(p.x)} سم من المقدمة و${_cm(p.y)} سم من الجنب'
                : 'اضغط على جهاز لاختياره، أو اضغط ضغطة طويلة واسحبه عشان تحركه، أو اضغط عليه ضغطتين عشان تلفه 90°.',
            style: const TextStyle(fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              const Text('خطوة الأسهم:'),
              for (final s in [1, 5, 10])
                ChoiceChip(
                  label: Text('$s سم'),
                  selected: _step == s,
                  onSelected: (_) => setState(() => _step = s),
                ),
            ],
          ),
          const SizedBox(height: 4),
          Center(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                IconButton.filledTonal(
                    onPressed: has ? () => _nudge(0, -1) : null,
                    icon: const Icon(Icons.arrow_upward)),
                Row(mainAxisSize: MainAxisSize.min, children: [
                  IconButton.filledTonal(
                      onPressed: has ? () => _nudge(-1, 0) : null,
                      icon: const Icon(Icons.arrow_back)),
                  IconButton.filledTonal(
                      onPressed: has ? () => _nudge(0, 1) : null,
                      icon: const Icon(Icons.arrow_downward)),
                  IconButton.filledTonal(
                      onPressed: has ? () => _nudge(1, 0) : null,
                      icon: const Icon(Icons.arrow_forward)),
                ]),
              ]),
            ),
          ),
          const Center(
            child: Text('الشمال = ناحية مقدمة الحاوية، واليمين = ناحية الباب',
                style: TextStyle(fontSize: 11, color: Colors.black54)),
          ),
          const SizedBox(height: 6),
          Row(children: [
            const Text('الأدوار في العمود:  '),
            IconButton.filledTonal(
                onPressed: has ? () => _setUnits(-1) : null,
                icon: const Icon(Icons.remove)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(has ? '${p.units}' : '-',
                  style: const TextStyle(
                      fontSize: 18, fontWeight: FontWeight.bold)),
            ),
            IconButton.filledTonal(
                onPressed: has ? () => _setUnits(1) : null,
                icon: const Icon(Icons.add)),
          ]),
          const SizedBox(height: 6),
          Wrap(spacing: 8, runSpacing: 4, children: [
            FilledButton.tonalIcon(
                onPressed: has ? _rotateSel : null,
                icon: const Icon(Icons.rotate_90_degrees_ccw),
                label: const Text('لف 90°')),
            FilledButton.tonalIcon(
                onPressed: has ? _copySel : null,
                icon: const Icon(Icons.copy),
                label: const Text('نسخ')),
            FilledButton.tonalIcon(
                onPressed: has ? _deleteSel : null,
                icon: const Icon(Icons.delete_outline),
                label: const Text('حذف')),
            FilledButton.tonalIcon(
                onPressed: _undo.isEmpty ? null : _undoOnce,
                icon: const Icon(Icons.undo),
                label: const Text('تراجع')),
            FilledButton.tonalIcon(
                onPressed: pl.isEmpty ? null : _clearAll,
                icon: const Icon(Icons.layers_clear),
                label: const Text('فضّي الحاوية')),
            PopupMenuButton<int>(
              onSelected: _addColumn,
              itemBuilder: (_) => [
                for (var i = 0; i < c.items.length; i++)
                  PopupMenuItem(
                      value: i, child: Text('إضافة عمود: ${c.items[i].tag}')),
              ],
              child: const Chip(
                  avatar: Icon(Icons.add), label: Text('إضافة عمود')),
            ),
          ]),
          SwitchListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            value: snap,
            onChanged: (v) => setState(() => snap = v),
            title: const Text('مغناطيس (يلزق في الجدران والأجهزة)'),
          ),
        ]),
      ),
    );
  }

  Widget _resultView(Calc c) {
    final r = c.result;
    final st = calcStats(c);
    final rem = max(0.0, c.L - st.usedLen);
    final over = c.overflow;
    final ov = c.overlapIdx;
    final overweight = c.payload > 0 && st.weight > c.payload;

    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      const SizedBox(height: 16),
      Card(
        color: Theme.of(context).colorScheme.primaryContainer,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(
                c.manual || c.edited
                    ? 'إجمالي الأجهزة في ترتيبك: ${r.total} جهاز'
                    : 'إجمالي المحمّل: ${r.total} جهاز',
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.bold)),
            const SizedBox(height: 6),
            Text(
                'استغلال الأرضية: ${st.floorPct.toStringAsFixed(0)}%   |   استغلال الحجم: ${st.volPct.toStringAsFixed(0)}%'),
            Text('الطول المستخدم: ${_cm(st.usedLen)} سم  (الحاوية ${_cm(c.L)} سم)'),
            if (over > 0.5)
              Text(
                'تنبيه: الحمولة أطول من الحاوية بـ ${_cm(over)} سم، و${c.outside} جهاز خارج الحاوية',
                style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.red),
              )
            else
              Text(
                rem > 0.5
                    ? 'المتبقي من طول الحاوية: ${_cm(rem)} سم'
                    : 'الحاوية ممتلئة طولياً (لا يوجد متبقي)',
                style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: rem > 0.5 ? Colors.green.shade800 : Colors.red),
              ),
            if (ov.isNotEmpty)
              Text(
                'تنبيه: في ${ov.length} عمود متداخلين مع بعض (باللون الأحمر في الرسمة)',
                style: const TextStyle(
                    color: Colors.red, fontWeight: FontWeight.bold),
              ),
            for (final w in c.warnings)
              Text('تنبيه: $w',
                  style: const TextStyle(
                      color: Colors.red, fontWeight: FontWeight.bold)),
            if (st.weight > 0)
              Text('الوزن الكلي: ${st.weight.toStringAsFixed(0)} كجم'),
            if (overweight)
              Text(
                  'تنبيه: الوزن أكبر من الحمولة القصوى (${c.payload.toStringAsFixed(0)} كجم)',
                  style: const TextStyle(
                      color: Colors.red, fontWeight: FontWeight.bold)),
            const Divider(),
            if (c.notes.isNotEmpty) ...[
              Text(
                  c.edited
                      ? 'حالة الترتيب:'
                      : 'ترتيب التحميل (من تعليماتك):',
                  style: const TextStyle(fontWeight: FontWeight.bold)),
              for (final n in c.notes) Text(n),
              const Divider(),
            ],
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
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: showNums,
        onChanged: (v) => setState(() => showNums = v),
        title: const Text('ترقيم الأجهزة (صف.عمود)'),
        subtitle: const Text('مثلاً 1.2 = الصف 1 العمود 2'),
      ),
      SwitchListTile(
        contentPadding: EdgeInsets.zero,
        value: editMode,
        onChanged: (v) => setState(() {
          editMode = v;
          if (!v) {
            sel = null;
            _drag = null;
          }
        }),
        title: const Text('تعديل الرسمة بإيدك (زي اللعبة)'),
        subtitle: const Text(
            'ضغطة طويلة + سحب = تحريك. ضغطتين = لف 90°. السحب العادي بيمرّر الرسمة.'),
      ),
      if (editMode) _editBar(c),
      Row(children: [
        const Icon(Icons.zoom_in),
        Expanded(
          child: Slider(
            value: zoom,
            min: 0.3,
            max: 3.0,
            divisions: 27,
            label: '${zoom.toStringAsFixed(1)}x',
            onChanged: (v) => setState(() => zoom = v),
          ),
        ),
      ]),
      LayoutBuilder(builder: (ctx, cons) {
        const m = 16.0;
        final totL = max(c.L, c.usedLen);
        final totW = max(c.W, c.usedWid);
        final fit = (cons.maxWidth - 2 * m) / totL;
        final scale = max(fit, 1.6) * zoom;
        final cw = totL * scale + 2 * m;
        final ch = LoadPainter.topPad + totW * scale + LoadPainter.bottomPad;

        final canvasW = CustomPaint(
          size: Size(cw, ch),
          painter: LoadPainter(c.L, c.W, scale, m, r.placed, c.items,
              sel: editMode ? (sel ?? -1) : -1,
              overlap: ov,
              showNums: showNums),
        );

        return Card(
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            physics:
                _drag != null ? const NeverScrollableScrollPhysics() : null,
            child: editMode
                ? GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => setState(
                        () => sel = _hit(d.localPosition, scale, m)),
                    onDoubleTapDown: (d) => _dtPos = d.localPosition,
                    onDoubleTap: () {
                      final i = _hit(_dtPos, scale, m);
                      if (i == null) return;
                      setState(() {
                        sel = i;
                        _rotateIdx(i);
                      });
                    },
                    onLongPressStart: (d) {
                      final i = _hit(d.localPosition, scale, m);
                      if (i == null) return;
                      HapticFeedback.mediumImpact();
                      setState(() {
                        _pushUndo();
                        sel = i;
                        _drag = i;
                        final p = result!.result.placed[i];
                        _grab = Offset(
                            (d.localPosition.dx - m) / scale - p.x,
                            (d.localPosition.dy - LoadPainter.topPad) /
                                    scale -
                                p.y);
                      });
                    },
                    onLongPressMoveUpdate: (d) {
                      final i = _drag;
                      if (i == null) return;
                      final nx =
                          (d.localPosition.dx - m) / scale - _grab.dx;
                      final ny =
                          (d.localPosition.dy - LoadPainter.topPad) / scale -
                              _grab.dy;
                      setState(() => _moveTo(i, nx, ny, scale));
                    },
                    onLongPressEnd: (_) => setState(() => _drag = null),
                    child: canvasW,
                  )
                : canvasW,
          ),
        );
      }),
      const Text(
          'الرقم الصغير على الجهاز = صف.عمود. المكتوب في نصه = نوع الجهاز وتحته عدد الأدوار. الخطوط المائلة = جهاز نايم. الخط الأحمر = ناحية الباب. الأحمر على الجهاز = خارج الحاوية أو متداخل. لو الحاوية طويلة صغّر الرسمة بالـ slider.',
          style: TextStyle(fontSize: 12, color: Colors.black54)),
      const SizedBox(height: 24),
    ]);
  }

  String _itemLine(Calc c, int i) {
    final it = c.items[i];
    final got = c.result.loaded[i];
    final pose = it.pose == 1 ? '' : '  [${it.poseName}]';
    final nm = it.label.isEmpty ? it.name : '${it.name} (${it.label})';

    if (c.edited) {
      if (it.qty > 0) {
        final left = it.qty - got;
        final tail = left > 0
            ? '(فاضل $left مش متحط)'
            : (left < 0 ? '(زيادة ${-left})' : '(الكل اتحط)');
        return '$nm: $got من ${it.qty} $tail$pose';
      }
      return '$nm: $got جهاز$pose';
    }
    if (c.manual) {
      return '$nm: $got جهاز  (${min(it.maxStack, it.qty)} أدوار)$pose';
    }

    if (it.fh > c.H) {
      return '$nm: ارتفاعه بالوضع ده أكبر من ارتفاع الحاوية، مش هيدخل$pose';
    }
    final k = min(it.maxStack, (c.H / it.fh + 1e-9).floor());
    final layers = k < it.maxStack
        ? '  (الارتفاع بيسمح بـ $k أدوار بس)'
        : '  ($k أدوار)';
    if (it.qty == 0) return '$nm: $got جهاز$layers$pose';
    final left = it.qty - got;
    return left > 0
        ? '$nm: $got من ${it.qty} (فاضل $left مش داخل)$layers$pose'
        : '$nm: $got من ${it.qty} (الكل دخل)$layers$pose';
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
          _title('تعليماتك بالكلام (اختياري)'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: TextField(
                controller: cInstr,
                minLines: 3,
                maxLines: 8,
                decoration: const InputDecoration(
                  border: OutlineInputBorder(),
                  hintText:
                      'سطر لكل جهاز، مثال:\nبوتاجاز 40 جهاز 3 جنب بعض 4 أدوار نايم ظهر\n50x80: 192 جهاز، 6 جنب بعض، 3 أدوار',
                ),
              ),
            ),
          ),
          const Padding(
            padding: EdgeInsets.only(bottom: 6),
            child: Text(
                'ابدأ السطر باسم الجهاز أو نوعه. الكلمات المفهومة: جهاز، جنب بعض، أدوار، واقف، نايم ظهر، نايم جنب، لف 90. اللي ما تكتبوش بيتاخد من الخانات. التعليمات دي للزر التاني بس.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
          ),
          const SizedBox(height: 6),
          FilledButton.icon(
            onPressed: _calculate,
            icon: const Icon(Icons.auto_awesome),
            label: const Text('احسب أفضل ترتيب (تلقائي)'),
          ),
          const SizedBox(height: 8),
          FilledButton.tonalIcon(
            onPressed: _calculateManual,
            icon: const Icon(Icons.edit_note),
            label: const Text('جرّب ترتيبي (بتعليماتي)'),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _startBlank,
            icon: const Icon(Icons.draw),
            label: const Text('افضي الحاوية وارسم بإيدك'),
          ),
          const Padding(
            padding: EdgeInsets.only(top: 6),
            child: Text(
                'ترتيبك: الأجهزة بتتحمّل من المقدمة للباب، وكل نوع في صفوف لوحده. لو الطول زاد عن الحاوية هيتكتب لك بالسنتي. "افضي الحاوية" بيفتح رسمة فاضية وإنت بتضيف الأعمدة وتحركها بإيدك.',
                style: TextStyle(fontSize: 12, color: Colors.black54)),
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
  static const double topPad = 24;
  static const double bottomPad = 84;

  final double L, W, scale, m;
  final List<Placed> placed;
  final List<ItemSpec> items;
  final int sel; // العمود المختار (-1 = مفيش)
  final Set<int> overlap; // الأعمدة المتداخلة
  final bool showNums; // ترقيم صف.عمود
  LoadPainter(this.L, this.W, this.scale, this.m, this.placed, this.items,
      {this.sel = -1,
      this.overlap = const <int>{},
      this.showNums = true});

  TextPainter _tp(String t, double fs, Color color) {
    return TextPainter(
      text: TextSpan(
          text: t,
          style: TextStyle(
              color: color, fontSize: fs, fontWeight: FontWeight.bold)),
      textDirection: _isLtr(t) ? TextDirection.ltr : TextDirection.rtl,
    )..layout();
  }

  void _text(Canvas canvas, String t, Offset center, double fs, Color color) {
    final tp = _tp(t, fs, color);
    tp.paint(canvas, center - Offset(tp.width / 2, tp.height / 2));
  }

  /// يكتب عدة أسطر في نص المستطيل ويصغّر الخط لحد ما تتناسب
  void _label(Canvas canvas, Rect r, List<String> lines, Color color) {
    for (var n = lines.length; n >= 1; n--) {
      for (double fs = 14; fs >= 7; fs -= 1) {
        final tps = [for (var i = 0; i < n; i++) _tp(lines[i], fs, color)];
        final w = tps.map((t) => t.width).reduce((a, b) => a > b ? a : b);
        final h = tps.fold<double>(0, (a, t) => a + t.height);
        if (w <= r.width - 4 && h <= r.height - 2) {
          var y = r.center.dy - h / 2;
          for (final t in tps) {
            t.paint(canvas, Offset(r.center.dx - t.width / 2, y));
            y += t.height;
          }
          return;
        }
      }
    }
  }

  @override
  void paint(Canvas canvas, Size size) {
    final s = scale;
    final cont = Rect.fromLTWH(m, topPad, L * s, W * s);
    canvas.drawRect(cont, Paint()..color = const Color(0xFFEEEEEE));

    double used = 0, usedW = 0;
    for (final p in placed) {
      used = max(used, p.x + p.w);
      usedW = max(usedW, p.y + p.h);
    }
    final totW = max(W, usedW);
    final rem = max(0.0, L - used);
    final over = max(0.0, used - L);
    final nums = showNums ? numbering(placed) : const <String>[];

    // المنطقة الفاضية
    if (rem > 0.5) {
      final er = Rect.fromLTRB(m + used * s, topPad, m + L * s, topPad + W * s);
      canvas.drawRect(er, Paint()..color = const Color(0x2200C853));
      _label(canvas, er, ['فاضي', '${_cm(rem)} سم'], const Color(0xFF1B5E20));
    }

    // الأجهزة
    for (var pi = 0; pi < placed.length; pi++) {
      final p = placed[pi];
      final it = items[p.item];
      final r = Rect.fromLTWH(m + p.x * s, topPad + p.y * s, p.w * s, p.h * s)
          .deflate(0.6);
      canvas.drawRect(r, Paint()..color = it.color.withAlpha(215));

      // خطوط مائلة للجهاز النايم
      if (it.pose != 1) {
        canvas.save();
        canvas.clipRect(r);
        final hp = Paint()
          ..color = Colors.white.withAlpha(70)
          ..strokeWidth = 1.5;
        for (double d = -r.height; d < r.width; d += 10) {
          canvas.drawLine(Offset(r.left + d, r.bottom),
              Offset(r.left + d + r.height, r.top), hp);
        }
        canvas.restore();
      }

      final outLen = p.x + p.w > L + 0.5;
      final outWid = p.y + p.h > W + 0.5;
      final ovl = overlap.contains(pi);

      // الجزء اللي طالع برّه الحاوية بالأحمر
      if (outLen) {
        final ox = max(r.left, m + L * s);
        canvas.drawRect(Rect.fromLTRB(ox, r.top, r.right, r.bottom),
            Paint()..color = const Color(0x66FF0000));
      }
      // المتداخل بالأحمر
      if (ovl) {
        canvas.drawRect(r, Paint()..color = const Color(0x55FF0000));
      }

      final bad = outLen || outWid || ovl;
      canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = bad ? 2.5 : 1
            ..color = bad ? Colors.red : Colors.black54);

      // نوع الجهاز + عدد الأدوار + الوضع (من غير المقاسات)
      final lines = <String>[it.tag];
      if (p.units > 1) lines.add('${p.units} أدوار');
      if (it.pose != 1) lines.add(it.poseShort);
      final lr = (showNums && r.height >= 40)
          ? Rect.fromLTRB(r.left, r.top + 12, r.right, r.bottom)
          : r;
      _label(canvas, lr, lines, Colors.white);

      // رقم الجهاز: صف.عمود
      if (showNums && pi < nums.length) {
        final tp = _tp(nums[pi], 9, Colors.white);
        final bw = tp.width + 6, bh = tp.height + 2;
        if (bw <= r.width - 3 && bh <= r.height - 3) {
          final badge = Rect.fromLTWH(r.left + 1.5, r.top + 1.5, bw, bh);
          canvas.drawRRect(
              RRect.fromRectAndRadius(badge, const Radius.circular(3)),
              Paint()..color = const Color(0xCC000000));
          tp.paint(canvas, Offset(badge.left + 3, badge.top + 1));
        }
      }
    }

    // العمود المختار (إطار أصفر فوق كله)
    if (sel >= 0 && sel < placed.length) {
      final p = placed[sel];
      final r = Rect.fromLTWH(m + p.x * s, topPad + p.y * s, p.w * s, p.h * s);
      canvas.drawRect(r, Paint()..color = const Color(0x33FFC107));
      canvas.drawRect(
          r,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 3.5
            ..color = const Color(0xFFFFB300));
    }

    // أرقام الصفوف فوق الرسمة
    final rows = buildRows(placed);
    for (var i = 0; i < rows.length; i++) {
      final r = rows[i];
      _text(canvas, '${i + 1}', Offset(m + (r.x + r.len / 2) * s, topPad / 2),
          12, Colors.black87);
    }

    // إطار الحاوية والباب
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

    // خطوط القياس: المستخدم والمتبقي / الزيادة
    void dim(double xa, double xb, double y, String label, Color col) {
      final p = Paint()
        ..color = col
        ..strokeWidth = 2;
      canvas.drawLine(Offset(xa, y), Offset(xb, y), p);
      canvas.drawLine(Offset(xa, y - 6), Offset(xa, y + 6), p);
      canvas.drawLine(Offset(xb, y - 6), Offset(xb, y + 6), p);
      _text(canvas, label, Offset((xa + xb) / 2, y + 16), 13, col);
    }

    final base = topPad + totW * s;
    final xUsed = m + used * s;
    final xEnd = m + L * s;
    dim(m, max(xUsed, m + 2), base + 14, 'المستخدم ${_cm(used)} سم',
        const Color(0xFF283593));
    if (over > 0.5) {
      dim(xEnd, xUsed, base + 50, 'زيادة عن الحاوية ${_cm(over)} سم',
          Colors.red);
    } else if (rem > 0.5) {
      dim(xUsed, xEnd, base + 50, 'المتبقي ${_cm(rem)} سم',
          const Color(0xFF2E7D32));
    } else {
      _text(canvas, 'لا يوجد متبقي في طول الحاوية',
          Offset((m + xEnd) / 2, base + 56), 13, Colors.red);
    }
  }

  @override
  bool shouldRepaint(covariant LoadPainter old) => true;
}