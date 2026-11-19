import AppKit

/// Offscreen self-tests that also run under `--automation --headless`, where no notch, ring, panel, menu-bar item or
/// hotkey starts, so nothing ever shows on the owner's screen. Each feature adds ONE line below (its own
/// `register()`, which only calls `DebugCommands.register`); the headless launch calls `registerAll()`.
/// A self-test builds its windows offscreen (x -20000), posts its own events to them and writes its result to `out`.
@MainActor
enum HeadlessChecks {
    static func registerAll() {
        NotchDashSelfTest.register()   // notch.selftest.dash: the dashboard and its tabs with real clicks, Esc, Edit Nook
        NotchCardsSelfTest.register()   // notch.selftest.cards: a card hangs from the island as one shape and follows its width and place live (open, close, wings, stacked, clicks)
        NotchPersistSelfTest.register()   // notch.selftest.persist: layouts, panels, heights and settings come back after a restart
        LivePanelsSelfTest.register()   // live.selftest: which live panels show, in what order; timers come back after a restart
        AgentsAutoOpenSelfTest.register()   // auto.selftest: the notch opens by itself on Agents (needs you, long task, error), cooldowns, in-use notch, the card
        AgentNookSelfTest.register()   // agentnook.selftest: the rooms, helpers, props, layout at 3 to 16 cells, the empty house, a real click
        WindowsFeature.registerSelfTests()
        AskAIQuickSelfTest.register()   // ai.selftest.quick: a dashboard question goes into Fast Ask AI, the open chat stays, the history stays short
        MirrorFeature.registerHeadless()   // mirror.selftest: the zoom math, the camera rules (never started when scripted), real clicks on an offscreen Mirror
        RadioSelfTest.register()   // radio.selftest: stations by place, playing, saved things, the live panel (fake player and directory)
        LEDSelfTest.register()   // led.selftest: the dot font, the ticker's modes, the queue, the agent announcements
        Dash90SelfTest.register()   // dash90.selftest: LCD time segments, LED levels, tab keys fit and the selected one is pressed, real clicks on a tab, Join, a to-do box, the Ask AI terminal
        AppIconInUse.register()   // icon.export: writes the app icon at every size (scripts/export-icon.sh)
        NookHoverSelfTest.register()   // nook.selftest.hover: every widget kind gets the hover background (8-bit and minimal, dark and light), pixels
        LookSelfTest.register()   // look.selftest: size and colours settings: defaults, the island grows by the factor and clicks still land, light preset pixels, the closed notch stays black, the tour writes its picks
        CalendarMergedSelfTest.register()   // calendar.selftest.merged: the Calendar and the To-dos are one tab: no To-dos key, every old To-dos entry opens the Calendar, heights, real clicks on a to-do
        RetroSelfTest.register()   // retro.selftest: the 90s kit (seven segments, pixel text columns, LED bar zones, bevel edges)
        DebugCommandsSelfTest.register()   // debug.selftest: outside automation a scout:// link runs only the app's own commands and never writes to out=
        AppLanguageSelfTest.register()   // language.selftest: Settings › General › Language (names, choosing, back to the Mac's); language.selftest.restart: the real restart
        L10nSelfTest.register()   // l10n.selftest: the translations (keys, placeholders, CFBundleLocalizations, lookups) and, in the pseudo build, no unwrapped English in sample views
        SettingsNotchSelfTest.register()   // settings.selftest.notch: the notch opens and stays held behind the Settings window, which floats above it; closing releases it
        #if !APPSTORE
        AgentTabSelfTest.registerHeadless()   // termtab.selftest.relaunch: agent tabs come back in their folders and resume
        #endif
    }
}
