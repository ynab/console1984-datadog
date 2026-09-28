# Changelog

All notable changes to this project are documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## Unreleased

- Fix `rails runner` going unaudited in apps that partially load Rake at boot
  (e.g. `require "rails/test_unit/railtie"`, which requires `rake/file_list`).
  Detection raised `NoMethodError` on `Rake.application` and failed open.

## 1.0.0 - 2026-08-26

- Initial version.
