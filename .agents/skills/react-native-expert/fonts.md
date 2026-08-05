# Fonts

## Integrate fonts at build time for native apps

Use the Expo font config plugin for native production builds. The plugin embeds
font files during the native build. Create a development build to test that
integration. Expo Go cannot load a new native font configuration.

```json
{
  "expo": {
    "plugins": [
      [
        "expo-font",
        {
          "fonts": ["./assets/fonts/Inter-Regular.ttf"]
        }
      ]
    ]
  }
}
```

The runtime `useFonts` hook remains valid for web and for environments where a
build-time integration cannot apply. Keep the splash screen visible until
runtime fonts either load or fail.

Check the current [Expo font documentation](https://docs.expo.dev/develop/user-interface/fonts/)
before you select the configuration shape for the installed Expo SDK.
