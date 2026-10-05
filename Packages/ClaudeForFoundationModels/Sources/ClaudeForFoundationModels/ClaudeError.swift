// Copyright 2026 Anthropic PBC
// SPDX-License-Identifier: Apache-2.0

// Modified for CashbackCounter: top-level declarations annotated with
// @available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
// so the package links into an iOS 26 deployment target. See VENDORED.md.

import Foundation

/// Errors surfaced by the Claude provider that don't map onto a
/// ``LanguageModelError`` case. App developers can pattern-match on these to
/// drive product flows (key entry).
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
public enum ClaudeError: LocalizedError, Sendable {
  /// No usable credential. Provide an API key via ``AuthMode/apiKey(_:)``,
  /// or, when using ``AuthMode/proxied(headers:)``, check that the proxy
  /// supplies authentication.
  case missingCredential
  /// App Attest can't run on this hardware (simulators, devices without a
  /// Secure Enclave). Use ``AuthMode/apiKey(_:)`` for development, or
  /// ``AuthMode/proxied(headers:)``.
  case attestationUnsupported
  /// The device supports App Attest but no credential could be obtained.
  /// Causes include the server rejecting the attestation or assertion, an
  /// unusable response, an unreachable credential store, and a client ID
  /// already in use against a different base URL.
  case attestationFailed

  public var errorDescription: String? {
    switch self {
    case .missingCredential:
      "No Claude credential. Provide an API key."
    case .attestationUnsupported:
      "App Attest is not supported on this device or simulator."
    case .attestationFailed:
      "App attestation failed to produce a credential."
    }
  }
}
