import Foundation

struct ContentViewDeterministicRepair {
    let name: String
    let edit: ContentViewDeterministicEdit
}

extension ContentViewRepairSupport {

    static func makeDeterministicEdit(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicEdit? {
        makeDeterministicRepair(for: diagnostic, source: source, snippet: snippet)?.edit
    }

    static func makeDeterministicRepair(
        for diagnostic: SwiftCompilerDiagnostic,
        source: String,
        snippet: ContentViewRepairSnippet
    ) -> ContentViewDeterministicRepair? {
        if let patch = observableObjectStructFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "observableObjectStructFix", edit: patch)
        }

        if let patch = helperViewConformanceFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "helperViewConformanceFix", edit: patch)
        }

        if let patch = observedObjectStateFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "observedObjectStateFix", edit: patch)
        }

        if let patch = duplicateBodyFix(for: diagnostic, source: source) {
            return ContentViewDeterministicRepair(name: "duplicateBodyFix", edit: patch)
        }

        if let patch = weakSelfCaptureInValueViewFix(for: diagnostic, source: source) {
            return ContentViewDeterministicRepair(name: "weakSelfCaptureInValueViewFix", edit: patch)
        }

        if let patch = nonOptionalContentViewSelfFix(for: diagnostic, source: source, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "nonOptionalContentViewSelfFix", edit: patch)
        }

        if let patch = textFieldNumberFormatterStyleFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "textFieldNumberFormatterStyleFix", edit: patch)
        }

        if let patch = nonOptionalGuardBindingFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "nonOptionalGuardBindingFix", edit: patch)
        }

        if let patch = frameArgumentOrderFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "frameArgumentOrderFix", edit: patch)
        }

        if let patch = horizontalAlignmentFrameFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "horizontalAlignmentFrameFix", edit: patch)
        }

        if let patch = invalidAlignmentGuideOverlayFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "invalidAlignmentGuideOverlayFix", edit: patch)
        }

        if let patch = intSliderBindingFix(for: diagnostic, source: source, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "intSliderBindingFix", edit: patch)
        }

        if let patch = misplacedFillModifierFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "misplacedFillModifierFix", edit: patch)
        }

        if let patch = unsupportedSystemColorFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "unsupportedSystemColorFix", edit: patch)
        }

        if let patch = nsColorOpacityFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "nsColorOpacityFix", edit: patch)
        }

        if let patch = stringClosedRangeAlphabetFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "stringClosedRangeAlphabetFix", edit: patch)
        }

        if let patch = privateMemberwiseInitializerFix(for: diagnostic, source: source) {
            return ContentViewDeterministicRepair(name: "privateMemberwiseInitializerFix", edit: patch)
        }

        if let patch = missingStoredPropertyFromInitializerFix(for: diagnostic, source: source) {
            return ContentViewDeterministicRepair(name: "missingStoredPropertyFromInitializerFix", edit: patch)
        }

        if let patch = stateInitializedFromStateFix(for: diagnostic, source: source, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "stateInitializedFromStateFix", edit: patch)
        }

        if let patch = dynamicMemberStateAliasFix(for: diagnostic, source: source, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "dynamicMemberStateAliasFix", edit: patch)
        }

        if let patch = equatableConformanceFix(for: diagnostic, source: source) {
            return ContentViewDeterministicRepair(name: "equatableConformanceFix", edit: patch)
        }

        if let patch = indexPathMacOSFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "indexPathMacOSFix", edit: patch)
        }

        if let patch = unknownKeyTypeFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "unknownKeyTypeFix", edit: patch)
        }

        if let patch = invalidKeyEquivalentMemberFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "invalidKeyEquivalentMemberFix", edit: patch)
        }

        if let patch = reservedKeywordEnumCaseFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "reservedKeywordEnumCaseFix", edit: patch)
        }

        if let patch = shadowedPropertySelfAssignmentFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "shadowedPropertySelfAssignmentFix", edit: patch)
        }

        if let patch = formattedNumericAssignmentFix(for: diagnostic, source: source, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "formattedNumericAssignmentFix", edit: patch)
        }

        if let patch = mutableLetAssignmentFix(for: diagnostic, source: source) {
            return ContentViewDeterministicRepair(name: "mutableLetAssignmentFix", edit: patch)
        }

        if let patch = identifiableConformanceFix(for: diagnostic, source: source, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "identifiableConformanceFix", edit: patch)
        }

        if let patch = missingBindingPrefixFix(for: diagnostic, source: source, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "missingBindingPrefixFix", edit: patch)
        }

        if let patch = missingDisplayStateFix(for: diagnostic, source: source) {
            return ContentViewDeterministicRepair(name: "missingDisplayStateFix", edit: patch)
        }

        if let patch = borderEdgesArgumentFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "borderEdgesArgumentFix", edit: patch)
        }

        if let patch = unsupportedControlGroupStyleFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "unsupportedControlGroupStyleFix", edit: patch)
        }

        if let patch = invalidColorInitializerFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "invalidColorInitializerFix", edit: patch)
        }

        if let patch = extraneousStringWrapperLabelFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "extraneousStringWrapperLabelFix", edit: patch)
        }

        if let patch = extraArgumentFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "extraArgumentFix", edit: patch)
        }

        if let patch = stringTextFieldFormatFix(for: diagnostic, source: source, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "stringTextFieldFormatFix", edit: patch)
        }

        if let patch = windowBackgroundColorFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "windowBackgroundColorFix", edit: patch)
        }

        if let patch = nonVoidButtonActionFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "nonVoidButtonActionFix", edit: patch)
        }

        if let patch = missingClosingParenthesisFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "missingClosingParenthesisFix", edit: patch)
        }

        if let patch = methodPowFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "methodPowFix", edit: patch)
        }

        if let patch = exponentOperatorFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "exponentOperatorFix", edit: patch)
        }

        if let patch = invalidImportFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "invalidImportFix", edit: patch)
        }

        if let patch = uiAlertHelperNoopFix(for: diagnostic, source: source) {
            return ContentViewDeterministicRepair(name: "uiAlertHelperNoopFix", edit: patch)
        }

        if let patch = unsupportedModifierFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "unsupportedModifierFix", edit: patch)
        }

        if let patch = invalidMonospacedDigitFontFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "invalidMonospacedDigitFontFix", edit: patch)
        }

        if let patch = unsupportedFocusModifierFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "unsupportedFocusModifierFix", edit: patch)
        }

        if let patch = numericTextFieldFix(for: diagnostic, source: source, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "numericTextFieldFix", edit: patch)
        }

        if let patch = optionalNumericTextFallbackFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "optionalNumericTextFallbackFix", edit: patch)
        }

        if let patch = numericIsEmptyFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "numericIsEmptyFix", edit: patch)
        }

        if let patch = roundedToPlacesFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "roundedToPlacesFix", edit: patch)
        }

        if let patch = simpleNumericConversionFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "simpleNumericConversionFix", edit: patch)
        }

        if let patch = substringToStringArgumentFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "substringToStringArgumentFix", edit: patch)
        }

        if let patch = characterSetContainsCharacterFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "characterSetContainsCharacterFix", edit: patch)
        }

        if let patch = malformedArraySliceFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "malformedArraySliceFix", edit: patch)
        }

        if let patch = contextMenuIndexHoistTypeCheckFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "contextMenuIndexHoistTypeCheckFix", edit: patch)
        }

        if let patch = optionalMapTypeCheckFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "optionalMapTypeCheckFix", edit: patch)
        }

        if let patch = ifConditionOperatorSpacingFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "ifConditionOperatorSpacingFix", edit: patch)
        }

        if let patch = malformedRangeIterationFix(for: diagnostic, source: source, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "malformedRangeIterationFix", edit: patch)
        }

        if let patch = powCoercionFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "powCoercionFix", edit: patch)
        }

        if let patch = doubleRangeIterationFix(for: diagnostic, snippet: snippet) {
            return ContentViewDeterministicRepair(name: "doubleRangeIterationFix", edit: patch)
        }

        return nil
    }
}
