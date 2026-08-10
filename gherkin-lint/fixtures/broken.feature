Feature: Deliberately broken scenarios

  Discrimination fixture. Every violation below is intentional and is asserted
  by name in gherkin-lint.test.mjs. This file must NEVER be fixed — if a rule
  stops firing here, the rule regressed. It parses cleanly on purpose, so the
  AST rules are reachable; unparseable input lives in broken-or.feature.

  Scenario: A stakeholder cannot confirm this outcome
    Given an empty allowlist
    When the allowlist is asked whether "5511987654321@s.whatsapp.net" may "send"
    Then it works

  Scenario: A step that leaks UI mechanics
    Given an empty allowlist
    When the operator clicks #submit
    Then the answer is refused

  Scenario: A step that leaks UI mechanics
    Given an empty allowlist
    When the operator waits for 3 seconds
    Then the answer is refused

  Scenario: Placeholder data instead of realistic values
    Given an empty allowlist
    And "foo" is granted "bar"
    When the allowlist is asked whether "foo" may "bar"
    Then the answer is refused

  Scenario: An assertion followed by another action
    Given an empty allowlist
    When "read" is granted to "5511987654321@s.whatsapp.net"
    Then the answer is permitted
    When "read" is revoked from "5511987654321@s.whatsapp.net"

  Scenario: A blank line splits these steps
    Given an empty allowlist
    When the allowlist is asked whether "5511987654321@s.whatsapp.net" may "send"

    Then the answer is refused

  Scenario: This scenario tests far too many behaviors at once for one name
    Given an empty allowlist
    And "5511987654321@s.whatsapp.net" is granted "read"
    And "5521998877665@s.whatsapp.net" is granted "send"
    And "5531997766554@s.whatsapp.net" is granted "group.add"
    And the daemon is running
    And the bridge is paused
    When the allowlist is asked whether "5511987654321@s.whatsapp.net" may "read"
    And the allowlist is asked whether "5521998877665@s.whatsapp.net" may "send"
    And the allowlist is asked whether "5531997766554@s.whatsapp.net" may "group.add"
    Then the answer is permitted
    And the allowlist holds 3 contacts
    And this line is deliberately padded out beyond the hundred and twenty character cap so that the line-length rule has something real to catch
