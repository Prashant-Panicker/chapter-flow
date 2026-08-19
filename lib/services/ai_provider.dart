/// Supported AI backends for chapter translation.
enum AiProvider {
  /// Moonshot Kimi (api.moonshot.ai)
  kimi,

  /// DeepSeek V4 Flash (api.deepseek.com)
  deepseekV4Flash,
}

extension AiProviderX on AiProvider {
  String get displayName {
    switch (this) {
      case AiProvider.kimi:
        return 'Kimi (Moonshot)';
      case AiProvider.deepseekV4Flash:
        return 'DeepSeek V4 Flash';
    }
  }

  String get modelId {
    switch (this) {
      case AiProvider.kimi:
        return 'kimi-k2.6';
      case AiProvider.deepseekV4Flash:
        return 'deepseek-v4-flash';
    }
  }

  /// OpenAI-compatible base URL (no trailing slash).
  String get baseUrl {
    switch (this) {
      case AiProvider.kimi:
        return 'https://api.moonshot.ai/v1';
      case AiProvider.deepseekV4Flash:
        return 'https://api.deepseek.com';
    }
  }

  /// Secure-storage key for this provider's API key.
  String get secureStorageKey {
    switch (this) {
      case AiProvider.kimi:
        return 'moonshot_api_key';
      case AiProvider.deepseekV4Flash:
        return 'deepseek_api_key';
    }
  }

  /// Whether temperature is locked to thinking mode (Kimi-only rule).
  bool get tiesTemperatureToThinking {
    return this == AiProvider.kimi;
  }

  static AiProvider fromId(String? id) {
    switch (id) {
      case 'deepseekV4Flash':
      case 'deepseek_v4_flash':
      case 'deepseek-v4-flash':
        return AiProvider.deepseekV4Flash;
      case 'kimi':
      default:
        return AiProvider.kimi;
    }
  }

  String get id {
    switch (this) {
      case AiProvider.kimi:
        return 'kimi';
      case AiProvider.deepseekV4Flash:
        return 'deepseekV4Flash';
    }
  }
}
