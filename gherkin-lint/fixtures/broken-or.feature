Feature: Or is not a Gherkin keyword

  Second discrimination fixture. `Or` reads like a keyword to someone coming
  from a boolean mindset, and it is the single most common invented keyword.
  It is also a hard parse failure, which is why it lives in its own file: once
  the parser rejects a document, every AST rule downstream is unreachable and
  would silently report nothing. Keeping this separate is what stops
  broken.feature's AST findings from being masked.

  Scenario: A contact is refused
    Given an empty allowlist
    When the allowlist is asked whether "5511987654321@s.whatsapp.net" may "send"
    Then the answer is refused
    Or the answer is permitted
