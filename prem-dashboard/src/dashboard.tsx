import { useState } from "react";
import {
  LineChart, Line, XAxis, YAxis, Tooltip, CartesianGrid,
  ResponsiveContainer, BarChart, Bar, Legend
} from "recharts";

export default function Dashboard() {
  const trendData = [
    { month: "Jan", Communication: 72, DecisionMaking: 60, Empathy: 80 },
    { month: "Feb", Communication: 74, DecisionMaking: 62, Empathy: 81 },
    { month: "Mar", Communication: 76, DecisionMaking: 64, Empathy: 82 },
    { month: "Apr", Communication: 78, DecisionMaking: 65, Empathy: 82 },
    { month: "May", Communication: 79, DecisionMaking: 63, Empathy: 83 },
    { month: "Jun", Communication: 78, DecisionMaking: 65, Empathy: 82 },
  ];

  const wordCloudData = [
    { word: "waiting", size: 40 },
    { word: "clear", size: 30 },
    { word: "support", size: 25 },
    { word: "respect", size: 20 },
    { word: "access", size: 18 },
    { word: "decision", size: 22 },
    { word: "time", size: 35 },
  ];

  const sentimentData = [
    { month: "Jan", Positive: 65, Neutral: 20, Negative: 15 },
    { month: "Feb", Positive: 70, Neutral: 15, Negative: 15 },
    { month: "Mar", Positive: 68, Neutral: 18, Negative: 14 },
    { month: "Apr", Positive: 72, Neutral: 16, Negative: 12 },
    { month: "May", Positive: 66, Neutral: 20, Negative: 14 },
    { month: "Jun", Positive: 69, Neutral: 19, Negative: 12 },
  ];

  const [selectedWord, setSelectedWord] = useState<string | null>(null);
  const [selectedMonth, setSelectedMonth] = useState<string | null>(null);

  const allComments = [
    { id: 1, month: "Jan", text: "Long waiting time but clear instructions.", sentiment: "Neutral", tags: ["waiting", "clear"] },
    { id: 2, month: "Feb", text: "Felt respected and supported by staff.", sentiment: "Positive", tags: ["respect", "support"] },
    { id: 3, month: "Mar", text: "Hard to access therapy room; explanations were not clear.", sentiment: "Negative", tags: ["access", "clear"] },
    { id: 4, month: "Apr", text: "Great support from therapists, decision-making shared.", sentiment: "Positive", tags: ["support", "decision"] },
    { id: 5, month: "May", text: "Too much time waiting between sessions.", sentiment: "Negative", tags: ["waiting", "time"] },
    { id: 6, month: "Jun", text: "Clear plan and respectful communication.", sentiment: "Positive", tags: ["clear", "respect"] },
  ];

  const filteredComments = allComments.filter((c) => {
    const byWord = selectedWord ? c.tags.includes(selectedWord) : true;
    const byMonth = selectedMonth ? c.month === selectedMonth : true;
    return byWord && byMonth;
  });

    // --- type-safe click handler for Recharts Bar onClick payload
  const handleBarClick = (payload: unknown) => {
    if (payload && typeof payload === "object" && "activeLabel" in payload) {
      const maybe = (payload as { activeLabel?: unknown }).activeLabel;
      if (typeof maybe === "string") {
        setSelectedMonth(maybe);
      }
    }
  };

  return (
    <div className="p-6 grid grid-cols-1 gap-6 bg-gray-50 min-h-screen">
      {/* Header */}
      <header className="flex justify-between items-center">
        <h1 className="text-2xl font-bold text-gray-800">Neurorehab PREM Dashboard (PoC)</h1>
        <div className="flex gap-2">
          <select className="p-2 rounded-xl border border-gray-300">
            <option>Date Range</option>
          </select>
          <select className="p-2 rounded-xl border border-gray-300">
            <option>Condition</option>
          </select>
          <select className="p-2 rounded-xl border border-gray-300">
            <option>Ward</option>
          </select>
          <select className="p-2 rounded-xl border border-gray-300">
            <option>Therapist</option>
          </select>
        </div>
      </header>

      {/* Metric Cards */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-6">
        {[
          { title: "Communication", score: "78%", trend: "+5%" },
          { title: "Decision-Making", score: "65%", trend: "-3%" },
          { title: "Empathy & Respect", score: "82%", trend: "Stable" },
          { title: "Coordination", score: "70%", trend: "-1%" },
          { title: "Environment", score: "88%", trend: "+2%" },
          { title: "Overall Experience (NPS)", score: "+45", trend: "↑" },
        ].map((card, i) => (
          <div
            key={i}
            className="bg-white shadow rounded-2xl p-4 flex flex-col justify-between hover:shadow-lg transition"
          >
            <h2 className="text-lg font-semibold text-gray-700">{card.title}</h2>
            <p className="text-3xl font-bold text-indigo-600">{card.score}</p>
            <p className="text-sm text-gray-500">Trend: {card.trend}</p>
            <button className="mt-2 text-sm text-blue-600 underline">Drill Down</button>
          </div>
        ))}
      </div>

      {/* Interactive Trend Charts */}
      <div className="bg-white rounded-2xl shadow p-6">
        <h2 className="text-xl font-bold mb-4 text-gray-700">Trend Over Time</h2>
        <ResponsiveContainer width="100%" height={300}>
          <LineChart data={trendData}>
            <CartesianGrid strokeDasharray="3 3" />
            <XAxis dataKey="month" />
            <YAxis domain={[50, 100]} />
            <Tooltip />
            <Line type="monotone" dataKey="Communication" stroke="#4f46e5" strokeWidth={2} />
            <Line type="monotone" dataKey="DecisionMaking" stroke="#16a34a" strokeWidth={2} />
            <Line type="monotone" dataKey="Empathy" stroke="#f59e0b" strokeWidth={2} />
          </LineChart>
        </ResponsiveContainer>
      </div>

      {/* Insights Section */}
      <div className="bg-white rounded-2xl shadow p-6">
        <h2 className="text-xl font-bold mb-2 text-gray-700">AI Insights</h2>
        <p className="text-gray-600">
          Patients frequently mention <span className="font-semibold">“waiting time”</span> and
          <span className="font-semibold"> “clear information”</span> in comments. Younger
          patients (&lt;40) report lower involvement in decisions.
        </p>
      </div>

      {/* Patient Feedback Explorer */}
      <div className="bg-white rounded-2xl shadow p-6">
        <h2 className="text-xl font-bold mb-4 text-gray-700">Patient Feedback Explorer</h2>
        <div className="flex flex-wrap gap-3">
          {wordCloudData.map((w, i) => (
            <button
              key={i}
              onClick={() => setSelectedWord(selectedWord === w.word ? null : w.word)}
              style={{ fontSize: `${w.size / 2}px` }}
              className={`text-indigo-600 font-semibold hover:text-indigo-800 cursor-pointer rounded-xl px-1 ${selectedWord === w.word ? "bg-indigo-50" : ""}`}
            >
              {w.word}
            </button>
          ))}
        </div>
        <p className="mt-3 text-sm text-gray-500">
          Click a word to filter comments. {selectedWord ? `Active filter: "${selectedWord}"` : "No word filter."}
        </p>
      </div>

      {/* Sentiment Heatmap */}
      <div className="bg-white rounded-2xl shadow p-6">
        <h2 className="text-xl font-bold mb-2 text-gray-700">Sentiment Over Time</h2>
        <p className="text-sm text-gray-500 mb-4">Click a bar to focus on a month.</p>
        <ResponsiveContainer width="100%" height={300}>
          <BarChart data={sentimentData}>
            <CartesianGrid strokeDasharray="3 3" />
            <XAxis dataKey="month" />
            <YAxis />
            <Tooltip />
            <Legend />
            {/* Use a typed helper to avoid `any` and keep ESLint happy */}
            <Bar dataKey="Positive" stackId="a" fill="#16a34a" onClick={handleBarClick} />
            <Bar dataKey="Neutral"  stackId="a" fill="#fbbf24" onClick={handleBarClick} />
            <Bar dataKey="Negative" stackId="a" fill="#dc2626" onClick={handleBarClick} />
          </BarChart>
        </ResponsiveContainer>
        <p className="mt-3 text-sm text-gray-500">{selectedMonth ? `Focused month: ${selectedMonth}` : "No month selected."}</p>
      </div>

      {/* Cooperative Layer: filtered comments */}
      <div className="bg-white rounded-2xl shadow p-6">
        <h2 className="text-xl font-bold mb-4 text-gray-700">Team Annotations & Discussion</h2>
        <div className="grid md:grid-cols-2 gap-6">
          <div>
            <h3 className="font-semibold text-gray-700 mb-2">Filtered Patient Comments</h3>
            <ul className="space-y-2 max-h-64 overflow-auto pr-2">
              {filteredComments.length === 0 && (
                <li className="text-sm text-gray-500">No comments match current filters.</li>
              )}
              {filteredComments.map((c) => (
                <li key={c.id} className="p-3 bg-gray-50 rounded-xl border">
                  <div className="text-xs text-gray-500 mb-1">{c.month} · {c.sentiment}</div>
                  <div className="text-gray-700">{c.text}</div>
                  <div className="text-xs text-gray-500 mt-1">tags: {c.tags.join(", ")}</div>
                </li>
              ))}
            </ul>
          </div>
          <div>
            <h3 className="font-semibold text-gray-700 mb-2">Team Threads</h3>
            <ul className="space-y-2">
              <li className="p-2 bg-gray-100 rounded-xl">📌 July dip in Coordination due to staff turnover.</li>
              <li className="p-2 bg-gray-100 rounded-xl">📌 Improvement project launched in August for patient communication.</li>
            </ul>
            <textarea
              placeholder="Add a comment..."
              className="mt-4 w-full p-3 border rounded-xl"
            ></textarea>
            <div className="flex items-center gap-2 mt-2 text-sm text-gray-500">
              <span>Filters bind to thread context:</span>
              <span className="px-2 py-1 bg-gray-100 rounded-full">{selectedWord || "no-word"}</span>
              <span className="px-2 py-1 bg-gray-100 rounded-full">{selectedMonth || "no-month"}</span>
            </div>
            <button className="mt-2 px-4 py-2 bg-indigo-600 text-white rounded-xl">Post Comment</button>
          </div>
        </div>
      </div>
    </div>
  );
}
