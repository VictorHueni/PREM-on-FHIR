{{ config(
    on_schema_change='sync_all_columns'
) }}

with src as (
  select
      period_month,
      org_id,
      coalesce(nullif(trim(theme_primary), ''), 'Unknown') as theme_primary,
      sentiment_label,
      sentiment_score
  from {{ ref('mart_prem_text_sentiment') }}
)

select
    period_month,
    org_id,
    theme_primary,

    count(*)                                   as n_comments,
    avg(sentiment_score)                       as avg_sentiment,          -- ignore nulls by default
    -- label distributions (use FILTER for clarity)
    count(*) filter (where sentiment_label = 'positive') as n_pos,
    count(*) filter (where sentiment_label = 'neutral')  as n_neu,
    count(*) filter (where sentiment_label = 'negative') as n_neg,

    -- derived rates
    case when count(*) > 0 then
      (count(*) filter (where sentiment_label = 'negative'))::float / count(*)
    end as neg_rate
from src
group by
    period_month, org_id, theme_primary
