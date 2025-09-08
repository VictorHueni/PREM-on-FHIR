{{ config(
    materialized='table',
    schema='mart',
    indexes=[
      {'columns': ['period_month','org_id']},
      {'columns': ['theme_primary','sentiment_label']},
    ]
) }}

-- Source: one row per text answer with sentiment + theme (may include nulls)
with src as (
  select
      period_month,
      org_id,
      -- normalize labels to avoid null/blank issues in charts
      coalesce(nullif(trim(theme_primary), ''), 'Uncategorized') as theme_primary,
      coalesce(nullif(trim(sentiment_label), ''), 'unscored')    as sentiment_label,
      1 as n
  from {{ ref('mart_prem_text_sentiment') }}
),

-- Base counts per month/org/theme/sentiment
base as (
  select
      period_month,
      org_id,
      theme_primary,
      sentiment_label,
      count(*) as n_comments
  from src
  group by 1,2,3,4
),

-- Totals per month/org/theme (to compute within-theme rates)
theme_totals as (
  select
      period_month,
      org_id,
      theme_primary,
      sum(n_comments) as n_theme
  from base
  group by 1,2,3
),

-- Final matrix with rates
final as (
  select
      b.period_month,
      b.org_id,
      b.theme_primary,
      b.sentiment_label,

      b.n_comments,               -- count for this Theme × Sentiment
      t.n_theme,                  -- total comments for this Theme (same month/org)
      case when t.n_theme > 0 then b.n_comments::float / t.n_theme end as pct_within_theme,

      -- convenience flags for quick filtering in BI tools
      (b.sentiment_label = 'negative')::boolean as is_negative,
      (b.sentiment_label = 'positive')::boolean as is_positive,
      (b.sentiment_label = 'neutral')::boolean  as is_neutral
  from base b
  join theme_totals t
    on t.period_month = b.period_month
   and t.org_id       = b.org_id
   and t.theme_primary= b.theme_primary
)

select * from final
