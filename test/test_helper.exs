ExUnit.start()

# Ensure all required applications are started for testing
Application.ensure_all_started(:bypass)
Application.ensure_all_started(:finch)

# Load test helpers
Code.require_file("support/test_helpers.ex", __DIR__)
