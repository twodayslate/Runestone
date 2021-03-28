//
//  TreeSitterLanguageMode.swift
//  
//
//  Created by Simon Støvring on 05/12/2020.
//

import Foundation
import TreeSitter

protocol TreeSitterLanguageModeDelegate: AnyObject {
    func treeSitterLanguageMode(_ languageMode: TreeSitterLanguageMode, bytesAt byteIndex: ByteCount) -> [Int8]?
}

final class TreeSitterLanguageMode: LanguageMode {
    weak var delegate: TreeSitterLanguageModeDelegate?
    var canHighlight: Bool {
        return rootLanguageLayer.canHighlight
    }

    private let stringView: StringView
    private let parser: TreeSitterParser
    private let lineManager: LineManager
    private let rootLanguageLayer: TreeSitterLanguageLayer
    private let operationQueue = OperationQueue()

    init(language: TreeSitterLanguage, stringView: StringView, lineManager: LineManager) {
        self.stringView = stringView
        self.lineManager = lineManager
        operationQueue.name = "TreeSitterLanguageMode"
        operationQueue.qualityOfService = .userInitiated
        parser = TreeSitterParser(encoding: language.textEncoding.treeSitterEncoding)
        rootLanguageLayer = TreeSitterLanguageLayer(language: language, parser: parser, stringView: stringView, lineManager: lineManager)
        parser.delegate = self
    }

    func parse(_ text: String) {
        rootLanguageLayer.parse(text)
    }

    func parse(_ text: String, completion: @escaping ((Bool) -> Void)) {
        operationQueue.cancelAllOperations()
        let operation = BlockOperation()
        operation.addExecutionBlock { [weak operation, weak self] in
            if let self = self, let operation = operation, !operation.isCancelled {
                self.parse(text)
                DispatchQueue.main.sync {
                    completion(!operation.isCancelled)
                }
            } else {
                DispatchQueue.main.sync {
                    completion(false)
                }
            }
        }
        operationQueue.addOperation(operation)
    }

    func textDidChange(_ change: LanguageModeTextChange) -> LanguageModeTextChangeResult {
        let bytesRemoved = change.byteRange.length
        let bytesAdded = change.newString.byteCount
        let edit = TreeSitterInputEdit(
            startByte: change.byteRange.location,
            oldEndByte: change.byteRange.location + bytesRemoved,
            newEndByte: change.byteRange.location + bytesAdded,
            startPoint: TreeSitterTextPoint(change.startLinePosition),
            oldEndPoint: TreeSitterTextPoint(change.oldEndLinePosition),
            newEndPoint: TreeSitterTextPoint(change.newEndLinePosition))
        return rootLanguageLayer.apply(edit)
    }

    func captures(in range: ByteRange) -> [TreeSitterCapture] {
        return rootLanguageLayer.captures(in: range)
    }
    
    func createLineSyntaxHighlighter() -> LineSyntaxHighlighter {
        return TreeSitterSyntaxHighlighter(languageMode: self, operationQueue: operationQueue)
    }

    func currentIndentLevel(of line: DocumentLineNode, using indentStrategy: IndentStrategy) -> Int {
        let measurer = IndentLevelMeasurer(stringView: stringView)
        return measurer.indentLevel(of: line, tabLength: indentStrategy.tabLength)
    }

    func strategyForInsertingLineBreak(
        from startLinePosition: LinePosition,
        to endLinePosition: LinePosition,
        using indentStrategy: IndentStrategy) -> InsertLineBreakIndentStrategy {
        let startLayerAndNode = rootLanguageLayer.layerAndNode(at: startLinePosition)
        let endLayerAndNode = rootLanguageLayer.layerAndNode(at: endLinePosition)
        if let indentationScopes = startLayerAndNode?.layer.language.indentationScopes ?? endLayerAndNode?.layer.language.indentationScopes {
            let indentController = TreeSitterIndentController(indentationScopes: indentationScopes, stringView: stringView, lineManager: lineManager, tabLength: indentStrategy.tabLength)
            let startNode = startLayerAndNode?.node
            let endNode = endLayerAndNode?.node
            return indentController.strategyForInsertingLineBreak(between: startNode, and: endNode, caretStartPosition: startLinePosition, caretEndPosition: endLinePosition)
        } else {
            return InsertLineBreakIndentStrategy(indentLevel: 0, insertExtraLineBreak: false)
        }
    }

    func syntaxNode(at linePosition: LinePosition) -> SyntaxNode? {
        if let node = rootLanguageLayer.layerAndNode(at: linePosition)?.node, let type = node.type {
            let startPosition = LinePosition(node.startPoint)
            let endPosition = LinePosition(node.endPoint)
            return SyntaxNode(type: type, startPosition: startPosition, endPosition: endPosition)
        } else {
            return nil
        }
    }

    func detectIndentStrategy() -> DetectedIndentStrategy {
        if let tree = rootLanguageLayer.tree {
            let detector = TreeSitterIndentStrategyDetector(lineManager: lineManager, tree: tree, stringView: stringView)
            return detector.detect()
        } else {
            return .unknown
        }
    }
}

extension TreeSitterLanguageMode: TreeSitterParserDelegate {
    func parser(_ parser: TreeSitterParser, bytesAt byteIndex: ByteCount) -> [Int8]? {
        return delegate?.treeSitterLanguageMode(self, bytesAt: byteIndex)
    }
}

private extension TreeSitterIndentationScopes.IndentScanLocation {
    func startPosition(from linePosition: LinePosition) -> LinePosition {
        switch self {
        case .caret:
            return linePosition
        case .lineStart:
            return LinePosition(row: linePosition.row, column: 0)
        }
    }
}
