import Foundation

@MainActor
extension WeatherFeature {
    static func registerSelfTests() {
        FeaturesSelfTest.add("meeting links: zoom, meet, teams, webex, none") {
            MeetingLink.find(in: [nil, "Join: https://us02web.zoom.us/j/123456789?pwd=abc"])?.service == "Zoom"
                && MeetingLink.find(in: ["https://meet.google.com/abc-defg-hij"])?.service == "Google Meet"
                && MeetingLink.find(in: ["x https://teams.microsoft.com/l/meetup-join/19%3ameeting_x ok"])?.service == "Teams"
                && MeetingLink.find(in: ["https://acme.webex.com/meet/jo"])?.service == "Webex"
                && MeetingLink.find(in: ["https://example.com/zoom.us/j/1", "Room 4B"]) == nil
        }
        FeaturesSelfTest.add("open-meteo parse") {
            let json = """
            {"utc_offset_seconds":7200,"current":{"temperature_2m":18.4,"weather_code":61,"is_day":0,"wind_speed_10m":12.5},
             "hourly":{"time":["2026-11-15T20:00","2026-11-15T21:00"],"temperature_2m":[18.0,17.5],"weather_code":[61,3],"is_day":[0,0]},
             "daily":{"temperature_2m_max":[21.1],"temperature_2m_min":[13.2],"sunrise":["2026-11-15T07:12"],"sunset":["2026-11-15T17:41"]}}
            """
            guard let s = try? OpenMeteo.parse(Data(json.utf8), placeName: "Athens") else { return false }
            return s.code == 61 && !s.isDay && s.hours.count == 2 && s.high == 21.1 && s.kind == .rain && s.sunset != nil
        }
    }
}
