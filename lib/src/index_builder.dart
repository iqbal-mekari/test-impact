import 'dart:io';

import 'package:analyzer/dart/analysis/analysis_context.dart';
import 'package:analyzer/dart/analysis/results.dart';
import 'package:analyzer/dart/ast/ast.dart';
import 'package:analyzer/dart/ast/visitor.dart';
import 'package:analyzer/dart/element/element.dart';
import 'package:analyzer/dart/element/type.dart';
import 'package:analyzer/error/error.dart';
import 'package:analyzer/source/source.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/analysis_context_collection.dart';
// ignore: implementation_imports
import 'package:analyzer/src/dart/analysis/byte_store.dart';
import 'package:path/path.dart' as p;

import 'index.dart';
import 'workspace.dart';

/// Resolves every lib/ and test/ library of the covered packages with
/// `package:analyzer` and records the declaration graph for
/// [ImpactIndex].
///
/// ```dart
/// final index = await IndexBuilder(ws).build();
/// ```
class IndexBuilder {
  /// Creates a builder over [packageDirs] (default: all of [ws]).
  IndexBuilder(this.ws, {Iterable<String>? packageDirs})
      : dirs = (packageDirs ?? ws.packages.map((e) => e.dir)).toSet();

  /// The workspace being indexed.
  final Workspace ws;

  /// Repo-relative package dirs to cover.
  final Set<String> dirs;

  final _unavailable = <String>{};
  final _indexed = <String>{};
  final _tainted = <String>{};
  final _decls = <String, Set<String>>{};
  final _edges = <String, Set<String>>{};
  final _imports = <String, Set<String>>{};
  final _wildcard = <String>{};

  /// Error codes seen in tainted libraries (diagnostics only).
  final errorCodes = <String, int>{};

  /// Builds the index. Throws only on unexpected analyzer failures.
  Future<ImpactIndex> build() async {
    final pkgs = [for (final d in dirs) ws.byDir(d)].nonNulls.toList();
    final available = <ImpactPackage>[];
    for (final pkg in pkgs) {
      final cfg =
          File(p.join(ws.root, pkg.dir, '.dart_tool', 'package_config.json'));
      if (cfg.existsSync()) {
        available.add(pkg);
      } else {
        _unavailable.add(pkg.dir);
        _wildcard.addAll(pkg.testFiles.map((t) => _join(pkg.dir, t)));
      }
    }
    // One context per package, rooted at lib/ (or test/). Its session
    // also resolves the package's test/ files and files excluded by
    // analysis_options (generated code), so each package is analyzed once.
    final roots = <String, String>{};
    for (final pkg in available) {
      for (final sub in ['lib', 'test']) {
        final dir = _abs(pkg.dir, sub);
        if (Directory(dir).existsSync()) {
          roots[pkg.dir] = dir;
          break;
        }
      }
    }
    final included = roots.values.toList();
    if (included.isNotEmpty) {
      // A shared byte store lets every package context reuse the linked
      // summaries of common dependencies (shared packages, Flutter) instead of
      // relinking them per package.
      final collection = AnalysisContextCollectionImpl(
          includedPaths: included, byteStore: MemoryByteStore());
      try {
        for (final pkg in available) {
          await _package(collection, pkg, roots[pkg.dir]);
        }
      } finally {
        await collection.dispose();
      }
    }
    _propagateWildcards();
    return ImpactIndex(
      root: ws.root,
      packages: dirs,
      unavailable: _unavailable,
      indexed: _indexed,
      tainted: _tainted,
      declsByFile: _decls,
      edges: _edges,
      imports: _imports,
      wildcardTests: _wildcard,
    );
  }

  Future<void> _package(AnalysisContextCollectionImpl collection,
      ImpactPackage pkg, String? rootPath) async {
    AnalysisContext? ctx;
    for (final c in collection.contexts) {
      if (rootPath != null && p.equals(c.contextRoot.root.path, rootPath)) {
        ctx = c;
      }
    }
    final files = [
      for (final f in pkg.files)
        if ((f.startsWith('lib/') || f.startsWith('test/')) &&
            f.endsWith('.dart'))
          f
    ];
    if (ctx == null) {
      _unavailable.add(pkg.dir);
      _wildcard.addAll(pkg.testFiles.map((t) => _join(pkg.dir, t)));
      return;
    }
    final session = ctx.currentSession;
    for (final f in files) {
      final rel = _join(pkg.dir, f);
      if (_indexed.contains(rel) || _tainted.contains(rel)) continue;
      final res = await session.getResolvedLibrary(_abs(pkg.dir, f));
      if (res is NotLibraryButPartResult) continue;
      if (res is! ResolvedLibraryResult) {
        _tainted.add(rel);
        if (_isTest(rel)) _wildcard.add(rel);
        continue;
      }
      _library(res);
    }
  }

  void _library(ResolvedLibraryResult lib) {
    final libRel = _rel(lib.element.source.fullName);
    if (libRel == null) return;
    final testNode = _isTest(libRel) ? '$testPrefix$libRel' : null;
    if (testNode != null) _edges.putIfAbsent(testNode, () => {});
    var broken = false;
    final unitFiles = <String>[];
    for (final unit in lib.units) {
      final uRel = _rel(unit.path);
      if (uRel == null) continue;
      unitFiles.add(uRel);
      for (final e in unit.errors) {
        if (e.errorCode.errorSeverity == ErrorSeverity.ERROR) {
          broken = true;
          final k = e.errorCode.name;
          errorCodes[k] = (errorCodes[k] ?? 0) + 1;
        }
      }
      final cu = unit.unit;
      final unitEl = cu.declaredElement;
      if (unitEl != null) _directives(uRel, unitEl);
      final declared = _decls.putIfAbsent(uRel, () => {});
      for (final member in cu.declarations) {
        final keys = _declaredKeys(member);
        final refs = _refs(member);
        for (final k in keys) {
          declared.add(k);
          _edges.putIfAbsent(k, () => {}).addAll(refs..remove(k));
        }
        if (testNode != null) {
          _edges.putIfAbsent(testNode, () => {}).addAll(keys);
        }
      }
      if (testNode != null) {
        final t = _edges.putIfAbsent(testNode, () => {});
        for (final d in cu.directives) {
          t.addAll(_refs(d));
        }
      }
    }
    if (broken) {
      _tainted.addAll(unitFiles);
      if (testNode != null) _wildcard.add(libRel);
    } else {
      _indexed.addAll(unitFiles);
    }
  }

  void _directives(String from, CompilationUnitElement unit) {
    final out = _imports.putIfAbsent(from, () => {});
    void add(Source? s) {
      final r = s == null ? null : _rel(s.fullName);
      if (r != null) out.add(r);
    }

    for (final i in unit.libraryImports) {
      add(i.importedLibrary?.source);
    }
    for (final e in unit.libraryExports) {
      add(e.exportedLibrary?.source);
    }
    for (final part in unit.parts) {
      final uri = part.uri;
      if (uri is DirectiveUriWithUnit) add(uri.unit.source);
    }
  }

  Set<String> _declaredKeys(CompilationUnitMember member) {
    final elements = <Element?>[
      if (member is TopLevelVariableDeclaration)
        for (final v in member.variables.variables) v.declaredElement
      else
        member.declaredElement,
    ];
    return {for (final e in elements) keyOf(e)}.nonNulls.toSet();
  }

  Set<String> _refs(AstNode node) {
    final v = _RefVisitor(this);
    node.accept(v);
    return v.keys;
  }

  /// Node key of the top-level declaration enclosing [element], or null
  /// when it lies outside the covered packages' lib/ and test/ trees.
  String? keyOf(Element? element) {
    if (element == null) return null;
    var cur = element.declaration ?? element;
    if (cur is MultiplyDefinedElement || cur is PrefixElement) return null;
    for (;;) {
      final parent = cur.enclosingElement3;
      if (parent == null || parent is LibraryElement) return null;
      if (parent is CompilationUnitElement) break;
      cur = parent;
    }
    final source = cur.source;
    if (source == null) return null;
    final rel = _rel(source.fullName);
    if (rel == null) return null;
    return '$rel#${_name(cur)}';
  }

  String _name(Element top) {
    if (top is PropertyAccessorElement) {
      return top.variable2?.name ?? top.name.replaceAll('=', '');
    }
    final name = top.name;
    if (name == null || name.isEmpty) {
      final unit = top.enclosingElement3;
      if (top is ExtensionElement && unit is CompilationUnitElement) {
        return '<extension${unit.extensions.indexOf(top)}>';
      }
      return '<unnamed>';
    }
    return name;
  }

  /// Repo-relative path of [abs] if it is a lib/ or test/ file of a
  /// covered package, else null.
  String? _rel(String abs) {
    final rel = p.posix.joinAll(p.split(p.relative(abs, from: ws.root)));
    if (rel.startsWith('..')) return null;
    String? best;
    for (final d in dirs) {
      if ((d == '.' || rel.startsWith('$d/')) &&
          (best == null || d.length > best.length)) {
        best = d;
      }
    }
    if (best == null) return null;
    final inPkg = best == '.' ? rel : rel.substring(best.length + 1);
    if (!inPkg.startsWith('lib/') && !inPkg.startsWith('test/')) return null;
    return rel;
  }

  /// Tests reaching a declaration whose file was not indexed cleanly
  /// (analysis errors, unresolved part, unavailable package) become
  /// wildcards: their reach is unknown, so they are always kept.
  void _propagateWildcards() {
    final opaque = <String>{};
    for (final tos in _edges.values) {
      for (final t in tos) {
        final file = t.substring(0, t.indexOf('#'));
        if (!_indexed.contains(file)) opaque.add(t);
      }
    }
    final reverse = <String, Set<String>>{};
    _edges.forEach((from, tos) {
      for (final t in tos) {
        reverse.putIfAbsent(t, () => {}).add(from);
      }
    });
    final seen = {...opaque};
    final queue = [...opaque];
    while (queue.isNotEmpty) {
      for (final n in reverse[queue.removeLast()] ?? const <String>{}) {
        if (!seen.add(n)) continue;
        if (n.startsWith(testPrefix)) {
          _wildcard.add(n.substring(testPrefix.length));
        } else {
          queue.add(n);
        }
      }
    }
  }

  bool _isTest(String rel) {
    if (!rel.endsWith('_test.dart')) return false;
    for (final d in dirs) {
      final prefix = d == '.' ? 'test/' : '$d/test/';
      if (rel.startsWith(prefix)) return true;
    }
    return false;
  }

  String _abs(String dir, String rel) => p.normalize(p.join(ws.root, dir, rel));

  static String _join(String dir, String rel) => dir == '.' ? rel : '$dir/$rel';
}

class _RefVisitor extends GeneralizingAstVisitor<void> {
  _RefVisitor(this.b);
  final IndexBuilder b;
  final keys = <String>{};

  void _el(Element? e) {
    final k = b.keyOf(e);
    if (k != null) keys.add(k);
  }

  void _type(DartType? t, [int depth = 0]) {
    if (t == null || depth > 3) return;
    final alias = t.alias;
    if (alias != null) {
      _el(alias.element);
      for (final a in alias.typeArguments) {
        _type(a, depth + 1);
      }
    }
    if (t is InterfaceType) {
      _el(t.element);
      for (final a in t.typeArguments) {
        _type(a, depth + 1);
      }
    } else if (t is FunctionType) {
      _type(t.returnType, depth + 1);
      for (final param in t.parameters) {
        _type(param.type, depth + 1);
      }
    }
  }

  @override
  void visitComment(Comment node) {}

  @override
  void visitNode(AstNode node) {
    switch (node) {
      case SimpleIdentifier():
        _el(node.staticElement);
      case NamedType():
        _el(node.element);
      case ConstructorName():
        _el(node.staticElement);
      case SuperConstructorInvocation():
        _el(node.staticElement);
      case RedirectingConstructorInvocation():
        _el(node.staticElement);
      case Annotation():
        _el(node.element);
      case ExtensionOverride():
        _el(node.element);
      case PatternField():
        _el(node.element);
      case RelationalPattern():
        _el(node.element);
      default:
        break;
    }
    if (node is CompoundAssignmentExpression) {
      _el(node.readElement);
      _el(node.writeElement);
    }
    if (node is MethodReferenceExpression) _el(node.staticElement);
    if (node is Expression) _type(node.staticType);
    super.visitNode(node);
  }
}
