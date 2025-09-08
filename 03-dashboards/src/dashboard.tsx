import { useMemo, useState } from "react";
import {
  LineChart,
  Line,
  XAxis,
  YAxis,
  Tooltip,
  CartesianGrid,
  ResponsiveContainer,
  BarChart,
  Bar,
  Legend,
  PieChart,
  Pie,
  Cell,
} from "recharts";

/**
 * Neurorehab PREM Dashboard (PoC)
 * ---------------------------------------------------------------------
 * This mock React dashboard mirrors the analytics marts you built in dbt.
 * It uses static in-memory data shaped like your marts, so you can plug in
 * real queries later (Metabase or API) with minimal refactoring.
 *
 * Marts covered:
 *  - mart_prem_kpi_monthly / daily → KPI cards + trendlines
 *  - mart_prem_kpi_daily (domain_metrics_json) → Domain charts
 *  - mart_prem_item_heatmap → Item × Org heatmap
 *  - mart_prem_outliers → Outliers table
 *  - mart_prem_text_sentiment / mart_prem_theme_summary → Text analytics
 *
 * Notes:
 *  - Styling via Tailwind. Recharts for visuals.
 *  - All numbers are mock values; replace data providers with real fetches.
 */

// ---------- Types mirroring your marts ----------

type KpiMonthly = {
  period_month: string; // e.g., '2025-01-01'
  org_id: string;
  clinician_id: string | null;
  encounter_class: string;
  responses_n: number;
  patients_n: number;
  encounters_n: number;
  overall_score_pct_mean: number; // 0..1
  overall_top_box_pct_mean: number; // 0..1
  overall_top2_box_pct_mean: number; // 0..1
};

type DomainMetrics = {
  score_pct_mean: number; // 0..1
  top_box_pct_mean: number; // 0..1
  top2_box_pct_mean: number; // 0..1
  completeness_pct_mean: number; // 0..1
};

type KpiDailyDomainJson = {
  [domain_key: string]: DomainMetrics;
};

type ItemHeat = {
  period_month: string;
  org_id: string;
  questionnaire_id: string;
  item_linkid: string;
  domain_key: string;
  answers_n: number;
  responses_n: number;
  mean_score_pct: number; // 0..1
  top_box_pct: number; // 0..1
  top2_box_pct: number; // 0..1
  problem_rate_pct: number; // 0..1 bottom-box
};

type OutlierRow = {
  period_month: string;
  entity_type: "org" | "clinician";
  entity_id: string;
  responses_n: number;
  overall_score_pct_mean: number; // 0..1
  network_mean: number; // 0..1
  network_stddev: number | null;
  z_score: number | null;
  is_outlier: boolean;
};

type TextSentiment = {
  period_month: string;
  org_id: string;
  sentiment_label: "positive" | "neutral" | "negative" | "unscored";
  sentiment_score: number | null; // -1..+1
  qr_id: string;
  item_linkid: string;
  text_raw: string;
};

type ThemeSummary = {
  period_month: string;
  org_id: string;
  theme_primary: string; // e.g., "Communication"
  n_comments: number;
  avg_sentiment: number | null; // -1..+1
  n_pos: number;
  n_neu: number;
  n_neg: number;
  neg_rate: number | null; // 0..1
};

// ---------- Mock data providers (aligned to marts) ----------

const kpiMonthlyMock: KpiMonthly[] = [
  { period_month: "2025-01-01", org_id: "OrgA", clinician_id: null, encounter_class: "INPATIENT", responses_n: 120, patients_n: 110, encounters_n: 115, overall_score_pct_mean: 0.76, overall_top_box_pct_mean: 0.48, overall_top2_box_pct_mean: 0.78 },
  { period_month: "2025-02-01", org_id: "OrgA", clinician_id: null, encounter_class: "INPATIENT", responses_n: 130, patients_n: 118, encounters_n: 121, overall_score_pct_mean: 0.78, overall_top_box_pct_mean: 0.50, overall_top2_box_pct_mean: 0.79 },
  { period_month: "2025-03-01", org_id: "OrgA", clinician_id: null, encounter_class: "INPATIENT", responses_n: 140, patients_n: 126, encounters_n: 130, overall_score_pct_mean: 0.79, overall_top_box_pct_mean: 0.52, overall_top2_box_pct_mean: 0.81 },
  { period_month: "2025-04-01", org_id: "OrgA", clinician_id: null, encounter_class: "INPATIENT", responses_n: 135, patients_n: 121, encounters_n: 127, overall_score_pct_mean: 0.80, overall_top_box_pct_mean: 0.54, overall_top2_box_pct_mean: 0.82 },
  { period_month: "2025-05-01", org_id: "OrgA", clinician_id: null, encounter_class: "INPATIENT", responses_n: 150, patients_n: 134, encounters_n: 140, overall_score_pct_mean: 0.79, overall_top_box_pct_mean: 0.53, overall_top2_box_pct_mean: 0.81 },
  { period_month: "2025-06-01", org_id: "OrgA", clinician_id: null, encounter_class: "INPATIENT", responses_n: 148, patients_n: 132, encounters_n: 139, overall_score_pct_mean: 0.81, overall_top_box_pct_mean: 0.55, overall_top2_box_pct_mean: 0.83 },
];

// domain_metrics_json exploded for latest month (Communication, Coordination, Respect, Safety)
const domainJsonLatest: KpiDailyDomainJson = {
  Communication: { score_pct_mean: 0.82, top_box_pct_mean: 0.58, top2_box_pct_mean: 0.86, completeness_pct_mean: 0.97 },
  Coordination: { score_pct_mean: 0.71, top_box_pct_mean: 0.46, top2_box_pct_mean: 0.78, completeness_pct_mean: 0.95 },
  Respect: { score_pct_mean: 0.84, top_box_pct_mean: 0.62, top2_box_pct_mean: 0.89, completeness_pct_mean: 0.98 },
  Safety: { score_pct_mean: 0.76, top_box_pct_mean: 0.49, top2_box_pct_mean: 0.83, completeness_pct_mean: 0.96 },
};

// item heatmap mock (items × org)
const itemHeatMock: ItemHeat[] = [
  { period_month: "2025-06-01", org_id: "OrgA", questionnaire_id: "NREQ", item_linkid: "Q1", domain_key: "Communication", answers_n: 148, responses_n: 140, mean_score_pct: 0.84, top_box_pct: 0.61, top2_box_pct: 0.9, problem_rate_pct: 0.06 },
  { period_month: "2025-06-01", org_id: "OrgA", questionnaire_id: "NREQ", item_linkid: "Q2", domain_key: "Communication", answers_n: 148, responses_n: 140, mean_score_pct: 0.79, top_box_pct: 0.54, top2_box_pct: 0.84, problem_rate_pct: 0.08 },
  { period_month: "2025-06-01", org_id: "OrgB", questionnaire_id: "NREQ", item_linkid: "Q1", domain_key: "Communication", answers_n: 120, responses_n: 116, mean_score_pct: 0.73, top_box_pct: 0.42, top2_box_pct: 0.76, problem_rate_pct: 0.12 },
  { period_month: "2025-06-01", org_id: "OrgB", questionnaire_id: "NREQ", item_linkid: "Q2", domain_key: "Communication", answers_n: 120, responses_n: 116, mean_score_pct: 0.69, top_box_pct: 0.38, top2_box_pct: 0.72, problem_rate_pct: 0.15 },
];

// outliers mock
const outliersMock: OutlierRow[] = [
  { period_month: "2025-06-01", entity_type: "org", entity_id: "OrgA", responses_n: 148, overall_score_pct_mean: 0.81, network_mean: 0.77, network_stddev: 0.02, z_score: 2.0, is_outlier: true },
  { period_month: "2025-06-01", entity_type: "org", entity_id: "OrgB", responses_n: 116, overall_score_pct_mean: 0.70, network_mean: 0.77, network_stddev: 0.02, z_score: -3.5, is_outlier: true },
  { period_month: "2025-06-01", entity_type: "clinician", entity_id: "Clin-123", responses_n: 55, overall_score_pct_mean: 0.83, network_mean: 0.78, network_stddev: 0.03, z_score: 1.67, is_outlier: false },
];

// text analytics mock
const textSentimentMock: TextSentiment[] = [
  { period_month: "2025-01-01", org_id: "OrgA", sentiment_label: "positive", sentiment_score: 0.6, qr_id: "qr1", item_linkid: "i1", text_raw: "Staff were very supportive and clear." },
  { period_month: "2025-03-01", org_id: "OrgA", sentiment_label: "negative", sentiment_score: -0.5, qr_id: "qr2", item_linkid: "i2", text_raw: "Long waiting time between sessions." },
  { period_month: "2025-06-01", org_id: "OrgA", sentiment_label: "neutral", sentiment_score: 0.0, qr_id: "qr3", item_linkid: "i3", text_raw: "Instructions were okay." },
];

const themeSummaryMock: ThemeSummary[] = [
  { period_month: "2025-06-01", org_id: "OrgA", theme_primary: "Communication", n_comments: 35, avg_sentiment: 0.35, n_pos: 25, n_neu: 6, n_neg: 4, neg_rate: 0.114 },
  { period_month: "2025-06-01", org_id: "OrgA", theme_primary: "Coordination", n_comments: 28, avg_sentiment: 0.10, n_pos: 12, n_neu: 6, n_neg: 10, neg_rate: 0.357 },
  { period_month: "2025-06-01", org_id: "OrgA", theme_primary: "Environment", n_comments: 18, avg_sentiment: 0.42, n_pos: 13, n_neu: 4, n_neg: 1, neg_rate: 0.055 },
];

// ---------- Helpers ----------

const pct = (v: number | null | undefined, digits = 0) =>
  v == null ? "—" : `${(v * 100).toFixed(digits)}%`;

const signed = (v: number, digits = 2) => (v >= 0 ? `+${v.toFixed(digits)}` : v.toFixed(digits));

const latestMonth = <T extends { period_month: string }>(rows: T[]): string | null => {
  if (!rows.length) return null;
  return rows.map(r => r.period_month).sort().slice(-1)[0];
};

// ---------- KPI Cards (aligned to mart_prem_kpi_monthly) ----------

function KpiCards({ rows }: { rows: KpiMonthly[] }) {
  const [org, setOrg] = useState<string>("OrgA");

  const month = useMemo(() => latestMonth(rows), [rows]);
  const scoped = useMemo(
    () => rows.filter(r => r.org_id === org && r.period_month === month),
    [rows, org, month]
  );
  const agg = scoped[0];

  const kpis = [
    { title: "Overall NREQ Score", value: pct(agg?.overall_score_pct_mean, 0), sub: "Avg of per-response scores" },
    { title: "Top-box %", value: pct(agg?.overall_top_box_pct_mean, 0), sub: "Share in top category" },
    { title: "Responses", value: agg ? agg.responses_n.toString() : "—", sub: "QuestionnaireResponses" },
    { title: "Comment volume", value: (scoped[0]?.responses_n ? Math.round(scoped[0].responses_n * 0.4) : 0).toString(), sub: "Approx. text answers" },
  ];

  return (
    <div className="grid grid-cols-1 sm:grid-cols-2 lg:grid-cols-4 gap-4">
      {kpis.map((k, i) => (
        <div key={i} className="bg-white shadow rounded-2xl p-4 hover:shadow-lg transition">
          <div className="text-sm text-gray-500">{k.title}</div>
          <div className="text-3xl font-bold text-indigo-600 mt-1">{k.value}</div>
          <div className="text-xs text-gray-400 mt-1">{k.sub}</div>
        </div>
      ))}
    </div>
  );
}

// ---------- Trendline (overall_score_pct_mean over period_month) ----------

function OverallTrend({ rows }: { rows: KpiMonthly[] }) {
  const byMonth = useMemo(() => {
    const m = new Map<string, KpiMonthly[]>();
    rows.forEach(r => {
      const key = r.period_month.slice(0, 7); // YYYY-MM
      m.set(key, [...(m.get(key) || []), r]);
    });
    return Array.from(m.entries())
      .sort(([a], [b]) => (a < b ? -1 : 1))
      .map(([mkey, arr]) => ({
        month: mkey,
        overall: arr.reduce((s, x) => s + x.overall_score_pct_mean, 0) / arr.length,
      }));
  }, [rows]);

  return (
    <div className="bg-white rounded-2xl shadow p-6">
      <div className="flex items-center justify-between mb-4">
        <h2 className="text-lg font-semibold text-gray-700">Overall NREQ Score — Trend</h2>
      </div>
      <ResponsiveContainer width="100%" height={280}>
        <LineChart data={byMonth}>
          <CartesianGrid strokeDasharray="3 3" />
          <XAxis dataKey="month" />
          <YAxis tickFormatter={(v) => `${Math.round(v * 100)}%`} domain={[0.5, 1]} />
          <Tooltip formatter={(v) => pct(Number(v), 0)} />
          <Line type="monotone" dataKey="overall" stroke="#4f46e5" strokeWidth={2} />
        </LineChart>
      </ResponsiveContainer>
    </div>
  );
}

// ---------- Domain bar (score + top-2-box) ----------

function DomainBars({ domainJson }: { domainJson: KpiDailyDomainJson }) {
  const data = Object.entries(domainJson).map(([domain_key, m]) => ({
    domain: domain_key,
    score: m.score_pct_mean,
    top2: m.top2_box_pct_mean,
  }));

  return (
    <div className="bg-white rounded-2xl shadow p-6">
      <h2 className="text-lg font-semibold text-gray-700 mb-4">Domain Scores (Score vs Top-2-Box)</h2>
      <ResponsiveContainer width="100%" height={280}>
        <BarChart data={data}>
          <CartesianGrid strokeDasharray="3 3" />
          <XAxis dataKey="domain" />
          <YAxis tickFormatter={(v) => `${Math.round(v * 100)}%`} domain={[0, 1]} />
          <Tooltip formatter={(v) => pct(Number(v), 0)} />
          <Legend />
          <Bar dataKey="score" fill="#4f46e5" name="Score" />
          <Bar dataKey="top2" fill="#16a34a" name="Top-2-Box" />
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}

// ---------- Item × Org Heatmap (simple CSS grid) ----------

function ItemHeatmap({ rows }: { rows: ItemHeat[] }) {
  const items = Array.from(new Set(rows.map(r => r.item_linkid)));
  const orgs = Array.from(new Set(rows.map(r => r.org_id)));

  const cell = (val: number) => {
    // map 0..1 → 0..120 (light → dark indigo)
    const hue = 248; // indigo
    const lightness = 96 - Math.round(val * 60);
    return `hsl(${hue} 90% ${lightness}% / 1)`;
  };

  return (
    <div className="bg-white rounded-2xl shadow p-6">
      <h2 className="text-lg font-semibold text-gray-700 mb-4">Item × Organization — Mean Score %</h2>
      <div className="overflow-auto">
        <div className="min-w-[640px]">
          <div className="grid" style={{ gridTemplateColumns: `160px repeat(${items.length}, minmax(80px,1fr))` }}>
            <div className="p-2 text-xs font-semibold text-gray-500">Org / Item</div>
            {items.map(it => (
              <div key={it} className="p-2 text-xs font-semibold text-gray-500 text-center">{it}</div>
            ))}
            {orgs.map(org => (
              <>
                <div key={`${org}-label`} className="p-2 text-sm text-gray-700 font-medium border-t">{org}</div>
                {items.map(it => {
                  const rec = rows.find(r => r.org_id === org && r.item_linkid === it);
                  const v = rec?.mean_score_pct ?? 0;
                  return (
                    <div key={`${org}-${it}`} className="border-t h-12 flex items-center justify-center text-sm" style={{ background: cell(v) }}>
                      <span className="font-semibold text-gray-800">{pct(v, 0)}</span>
                    </div>
                  );
                })}
              </>
            ))}
          </div>
        </div>
      </div>
    </div>
  );
}

// ---------- Outliers table ----------

function Outliers({ rows }: { rows: OutlierRow[] }) {
  return (
    <div className="bg-white rounded-2xl shadow p-6">
      <h2 className="text-lg font-semibold text-gray-700 mb-3">Outliers (z-score vs network mean)</h2>
      <div className="overflow-auto">
        <table className="min-w-full text-sm">
          <thead>
            <tr className="text-left text-gray-500">
              <th className="py-2 pr-4">Entity</th>
              <th className="py-2 pr-4">Responses</th>
              <th className="py-2 pr-4">Score</th>
              <th className="py-2 pr-4">Network mean</th>
              <th className="py-2 pr-4">z-score</th>
              <th className="py-2 pr-4">Flag</th>
            </tr>
          </thead>
          <tbody>
            {rows.map((r, i) => (
              <tr key={i} className="border-t">
                <td className="py-2 pr-4">{r.entity_type}:{" "}{r.entity_id}</td>
                <td className="py-2 pr-4">{r.responses_n}</td>
                <td className="py-2 pr-4">{pct(r.overall_score_pct_mean)}</td>
                <td className="py-2 pr-4">{pct(r.network_mean)}</td>
                <td className={`py-2 pr-4 ${r.z_score && Math.abs(r.z_score) >= 2 ? "text-red-600 font-semibold" : "text-gray-700"}`}>{r.z_score?.toFixed(2) ?? "—"}</td>
                <td className="py-2 pr-4">{r.is_outlier ? "🚨" : "—"}</td>
              </tr>
            ))}
          </tbody>
        </table>
      </div>
    </div>
  );
}

// ---------- Text analytics ----------

const SENTIMENT_COLORS = {
  positive: "#16a34a",
  neutral: "#fbbf24",
  negative: "#dc2626",
  unscored: "#9ca3af",
};

function SentimentDonut({ rows }: { rows: TextSentiment[] }) {
  const counts = rows.reduce(
    (acc, r) => ({ ...acc, [r.sentiment_label]: (acc[r.sentiment_label] || 0) + 1 }),
    {} as Record<string, number>
  );
  const data = Object.entries(counts).map(([k, v]) => ({ name: k, value: v }));

  return (
    <div className="bg-white rounded-2xl shadow p-6">
      <h2 className="text-lg font-semibold text-gray-700 mb-4">Sentiment distribution</h2>
      <ResponsiveContainer width="100%" height={260}>
        <PieChart>
          <Pie data={data} dataKey="value" nameKey="name" outerRadius={100}>
            {data.map((entry, index) => (
              <Cell key={`cell-${index}`} fill={(SENTIMENT_COLORS as any)[entry.name] || "#8884d8"} />
            ))}
          </Pie>
          <Tooltip />
          <Legend />
        </PieChart>
      </ResponsiveContainer>
    </div>
  );
}

function ThemeStacked({ rows }: { rows: ThemeSummary[] }) {
  const data = rows.map(r => ({
    theme: r.theme_primary,
    positive: r.n_pos,
    neutral: r.n_neu,
    negative: r.n_neg,
  }));

  return (
    <div className="bg-white rounded-2xl shadow p-6">
      <h2 className="text-lg font-semibold text-gray-700 mb-4">Themes × Sentiment</h2>
      <ResponsiveContainer width="100%" height={280}>
        <BarChart data={data}>
          <CartesianGrid strokeDasharray="3 3" />
          <XAxis dataKey="theme" />
          <YAxis />
          <Tooltip />
          <Legend />
          <Bar dataKey="positive" stackId="a" fill={SENTIMENT_COLORS.positive} />
          <Bar dataKey="neutral" stackId="a" fill={SENTIMENT_COLORS.neutral} />
          <Bar dataKey="negative" stackId="a" fill={SENTIMENT_COLORS.negative} />
        </BarChart>
      </ResponsiveContainer>
    </div>
  );
}

function Verbatims({ rows }: { rows: TextSentiment[] }) {
  return (
    <div className="bg-white rounded-2xl shadow p-6">
      <h2 className="text-lg font-semibold text-gray-700 mb-3">Recent Patient Comments (sample)</h2>
      <ul className="space-y-2 max-h-64 overflow-auto pr-2">
        {rows.map((r, i) => (
          <li key={i} className="p-3 bg-gray-50 rounded-xl border">
            <div className="text-xs text-gray-500 mb-1">{r.period_month.slice(0,7)} · {r.sentiment_label}</div>
            <div className="text-gray-800">{r.text_raw}</div>
          </li>
        ))}
      </ul>
    </div>
  );
}

// ---------- Main Dashboard ----------

export default function Dashboard() {
  const [orgId, setOrgId] = useState<string>("OrgA");

  return (
    <div className="p-6 grid grid-cols-1 gap-6 bg-gray-50 min-h-screen">
      {/* Header */}
      <header className="flex flex-col md:flex-row md:items-center md:justify-between gap-3">
        <h1 className="text-2xl font-bold text-gray-800">Neurorehab PREM Dashboard (Mock PoC)</h1>
        <div className="flex gap-2">
          <select value={orgId} onChange={(e) => setOrgId(e.target.value)} className="p-2 rounded-xl border border-gray-300">
            <option value="OrgA">OrgA</option>
            <option value="OrgB">OrgB</option>
          </select>
          <select className="p-2 rounded-xl border border-gray-300">
            <option>Date Range</option>
          </select>
          <select className="p-2 rounded-xl border border-gray-300">
            <option>Encounter class</option>
          </select>
        </div>
      </header>

      {/* KPI Cards */}
      <KpiCards rows={kpiMonthlyMock.filter(r => r.org_id === orgId)} />

      {/* Overall Trend */}
      <OverallTrend rows={kpiMonthlyMock.filter(r => r.org_id === orgId)} />

      {/* Domain bars (use latest domain JSON mock) */}
      <DomainBars domainJson={domainJsonLatest} />

      {/* Item × Org heatmap */}
      <ItemHeatmap rows={itemHeatMock} />

      {/* Outliers */}
      <Outliers rows={outliersMock} />

      {/* Text analytics row */}
      <div className="grid grid-cols-1 lg:grid-cols-2 gap-6">
        <SentimentDonut rows={textSentimentMock.filter(r => r.org_id === orgId)} />
        <ThemeStacked rows={themeSummaryMock.filter(r => r.org_id === orgId)} />
      </div>

      {/* Verbatims */}
      <Verbatims rows={textSentimentMock.filter(r => r.org_id === orgId)} />
    </div>
  );
}
