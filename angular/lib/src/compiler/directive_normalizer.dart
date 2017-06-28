import "dart:async";

import "package:angular/src/core/metadata/view.dart" show ViewEncapsulation;
import "package:angular/src/core/url_resolver.dart" show UrlResolver;
import "package:angular/src/facade/exceptions.dart" show BaseException;

import "compile_metadata.dart"
    show CompileTypeMetadata, CompileDirectiveMetadata, CompileTemplateMetadata;
import "html_ast.dart";
import "html_parser.dart" show HtmlParser;
import "style_url_resolver.dart" show extractStyleUrls, isStyleUrlResolvable;
import "template_preparser.dart" show preparseElement, PreparsedElementType;
import 'xhr.dart' show XHR;

class DirectiveNormalizer {
  final XHR _xhr;
  final UrlResolver _urlResolver;
  final HtmlParser _htmlParser;
  DirectiveNormalizer(this._xhr, this._urlResolver, this._htmlParser);
  Future<CompileDirectiveMetadata> normalizeDirective(
      CompileDirectiveMetadata directive) {
    if (!directive.isComponent) {
      // For non components there is nothing to be normalized yet.
      return new Future.value(directive);
    }
    return this.normalizeTemplate(directive.type, directive.template).then(
        (CompileTemplateMetadata normalizedTemplate) =>
            new CompileDirectiveMetadata(
                type: directive.type,
                isComponent: directive.isComponent,
                selector: directive.selector,
                exportAs: directive.exportAs,
                changeDetection: directive.changeDetection,
                inputs: directive.inputs,
                inputTypes: directive.inputTypes,
                outputs: directive.outputs,
                hostListeners: directive.hostListeners,
                hostProperties: directive.hostProperties,
                hostAttributes: directive.hostAttributes,
                lifecycleHooks: directive.lifecycleHooks,
                providers: directive.providers,
                viewProviders: directive.viewProviders,
                exports: directive.exports,
                queries: directive.queries,
                viewQueries: directive.viewQueries,
                template: normalizedTemplate));
  }

  Future<CompileTemplateMetadata> normalizeTemplate(
    CompileTypeMetadata directiveType,
    CompileTemplateMetadata template,
  ) {
    // This emulates the same behavior for interpreted mode, that is, that
    // omitting either template: or templateUrl: results in an empty template.
    template ??= new CompileTemplateMetadata(template: '');
    if (template.template != null) {
      return new Future.value(this.normalizeLoadedTemplate(
          directiveType,
          template,
          template.template,
          directiveType.moduleUrl,
          template.preserveWhitespace));
    } else if (template.templateUrl != null) {
      var sourceAbsUrl = this
          ._urlResolver
          .resolve(directiveType.moduleUrl, template.templateUrl);
      return this._xhr.get(sourceAbsUrl).then((templateContent) => this
          .normalizeLoadedTemplate(directiveType, template, templateContent,
              sourceAbsUrl, template.preserveWhitespace));
    } else {
      throw new BaseException(
          'No template specified for component ${directiveType.name}');
    }
  }

  CompileTemplateMetadata normalizeLoadedTemplate(
      CompileTypeMetadata directiveType,
      CompileTemplateMetadata templateMeta,
      String template,
      String templateAbsUrl,
      bool preserveWhitespace) {
    var rootNodesAndErrors =
        this._htmlParser.parse(template, directiveType.name);
    if (rootNodesAndErrors.errors.isNotEmpty) {
      var errorString = rootNodesAndErrors.errors.join('\n');
      throw new BaseException('Template parse errors: $errorString');
    }
    var visitor = new TemplatePreparseVisitor();
    htmlVisitAll(visitor, rootNodesAndErrors.rootNodes);
    List<String> allStyles =
        (new List.from(templateMeta.styles)..addAll(visitor.styles));
    List<String> allStyleAbsUrls = (new List.from(visitor.styleUrls
        .where(isStyleUrlResolvable)
        .toList()
        .map((url) => this._urlResolver.resolve(templateAbsUrl, url))
        .toList())
      ..addAll(templateMeta.styleUrls
          .where(isStyleUrlResolvable)
          .toList()
          .map((url) => this._urlResolver.resolve(directiveType.moduleUrl, url))
          .toList()));
    var allResolvedStyles = allStyles.map((style) {
      var styleWithImports =
          extractStyleUrls(this._urlResolver, templateAbsUrl, style);
      styleWithImports.styleUrls
          .forEach((styleUrl) => allStyleAbsUrls.add(styleUrl));
      return styleWithImports.style;
    }).toList();
    var encapsulation = templateMeta.encapsulation;
    if (identical(encapsulation, ViewEncapsulation.Emulated) &&
        identical(allResolvedStyles.length, 0) &&
        identical(allStyleAbsUrls.length, 0)) {
      encapsulation = ViewEncapsulation.None;
    }
    return new CompileTemplateMetadata(
        encapsulation: encapsulation,
        template: template,
        templateUrl: templateAbsUrl,
        styles: allResolvedStyles,
        styleUrls: allStyleAbsUrls,
        ngContentSelectors: visitor.ngContentSelectors,
        preserveWhitespace: preserveWhitespace);
  }
}

class TemplatePreparseVisitor implements HtmlAstVisitor {
  List<String> ngContentSelectors = [];
  List<String> styles = [];
  List<String> styleUrls = [];
  num ngNonBindableStackCount = 0;

  @override
  bool visit(HtmlAst ast, dynamic context) => false;

  @override
  dynamic visitElement(HtmlElementAst ast, dynamic context) {
    var preparsedElement = preparseElement(ast);
    if (preparsedElement.isNgContent) {
      if (identical(this.ngNonBindableStackCount, 0)) {
        this.ngContentSelectors.add(preparsedElement.selectAttr);
      }
    } else if (preparsedElement.isStyle) {
      var textContent = "";
      ast.children.forEach((child) {
        if (child is HtmlTextAst) {
          textContent += child.value;
        }
      });
      styles.add(textContent);
    } else if (preparsedElement.isStyleSheet) {
      styleUrls.add(preparsedElement.hrefAttr);
    } else {
      // DDC reports this as error. See:
      // https://github.com/dart-lang/dev_compiler/issues/428
    }
    if (preparsedElement.nonBindable) {
      ngNonBindableStackCount++;
    }
    htmlVisitAll(this, ast.children);
    if (preparsedElement.nonBindable) {
      ngNonBindableStackCount--;
    }
    return null;
  }

  @override
  dynamic visitComment(HtmlCommentAst ast, dynamic context) {
    return null;
  }

  @override
  dynamic visitAttr(HtmlAttrAst ast, dynamic context) {
    return null;
  }

  @override
  dynamic visitText(HtmlTextAst ast, dynamic context) {
    return null;
  }
}