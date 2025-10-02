| Page | Indicator                          | Mart                     | Concept                                                                                                                                                                                                 | Formulae / Comments |
|------|------------------------------------|--------------------------|---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------|---------------------|
| home | Responses per questionnaire     | mart_home_response_base  | Number of QuestionnaireResponses (QRs) collected for each distinct questionnaire (instrument). Useful to compare usage and response volumes across PREM or PROM instruments. | $$ \text{ResponsesByQuestionnaire}(q) = \sum_{r \in \mathcal{R}} \mathbf{1}\{ Q(r) = q \} $$ |
| home | Total responses                 | mart_home_response_base  | Total number of QuestionnaireResponses (QRs) returned by the current filters (period, org, questionnaire, etc.). One row in `mart_home_response_base` = one QR.             | $$ \text{Responses} = \sum_{r \in \mathcal{R}} 1 $$ |
| home | Distinct patients               | mart_home_response_base  | Number of unique patients who appear in the selected responses—i.e., individuals contributing at least one QR in the filtered window.                                       | $$ \text{Patients} = \left| \{ r.\text{patient\_id} : r \in \mathcal{R} \} \right| $$ |
| home | Completeness                    | mart_home_response_base  | For a given QR, the share of all expected leaf items that received any answer (whether scored or not).                                                                      | $$ \text{completion\_ratio\_total} = \tfrac{\#\text{answers to leaf items}}{\#\text{expected leaf items}} $$ |
| home | Has free text                   | mart_home_response_base  | Proportion of responses that contain at least one open-ended answer.                                                                                                        | $ \text{FreeTextRate} = \tfrac{1} {|\mathcal{R}|} \sum_{r \in \mathcal{R}} r.\text{has\_freetext\_int} = \tfrac{\#\{ r \in \mathcal{R} \mid r.\text{has\_freetext\_int}=1 \}}{|\mathcal{R}|} $ |
| home | Trends (responses over time)    | mart_home_trend_daily    | Tracks evolution over time of how many QRs are authored, optionally per questionnaire.                                                                                      | $$ \text{Responses}(d,q) = \sum_{r \in \mathcal{R}} \mathbf{1}\{ r.\text{qr\_date}=d \wedge r.\text{questionnaire\_id}=q \} $$ |
| home | Response volume                 | mart_home_staleness      | Total number of QRs (`fact_prem_response`) collected for a given org × questionnaire.                                                                                       | $$ \text{responses\_n}(o,q) = \sum_{r \in \mathcal{R}_{o,q}} 1 $$ |
| home | Last seen answer                | mart_home_staleness      | Timestamp of the most recent answered item for a questionnaire in an organization.                                                                                          | $$ \text{last\_seen\_answer}(o,q) = \max\{ a.\text{authored\_ts} : a \in A_{o,q} \} $$ |
| home | Days since last answer          | mart_home_staleness      | Number of days since the most recent answered item for a questionnaire in an organization.                                                                                  | $$ \text{days\_since\_last\_answer}(o,q) = \text{today} - \max\{ a.\text{authored\_ts} : a \in A_{o,q} \} $$ |
| home | Questionnaire last updated      | mart_home_staleness      | Metadata timestamp of when the questionnaire resource itself was last updated.                                                                                              | $$ \text{last\_updated}(q) = \text{questionnaire\_last\_updated}(q) $$ |
| home | Questionnaire staleness per org | mart_home_staleness      | Number of days since the questionnaire definition was updated in the source system, reported per org.                                                                       | $$ \text{days\_since\_last\_update}(q) = \text{today} - \text{questionnaire\_last\_updated}(q) $$ |
| nreq | Overall Score (nreq)            | mart_prem_kpi_daily      | Daily mean of the response-level overall score across all NREQ responses in scope.                                                                                          | $\text{overall\_score\_pct\_mean}(d) = \frac{1}{|\mathcal{R}_d|}\sum_{r \in \mathcal{R}_d} \text{overall\_score\_pct}(r)$ |
| nreq | Top Box % (nreq)                | mart_prem_kpi_daily      | Daily mean of the response-level top-box percentage across all NREQ responses in scope.                                                                                     | $$ \text{overall\_top\_box\_pct\_mean}(d) = \frac{1}{|\mathcal{R}_d|}\sum_{r \in \mathcal{R}_d} \text{overall\_top\_box\_pct}(r) $$ |
| stg  | score_pct (answer level)        | stg_answers             | Normalized score for a single answer on a Likert/ordinal item, scaled to [0,1].                                                                                            | $$ \text{score\_pct}(a) = \frac{\text{numeric\_value}(a)}{\text{likert\_max\_for\_item}} $$ |
| stg  | overall_score (response level)  | stg_responses           | Mean of `score_pct` over all scored answers in a response.                                                                                                                 | $$ \text{overall\_score\_pct}(r) = \frac{1}{N_r}\sum_{a \in A_r} \text{score\_pct}(a) $$ |
| stg  | answer_is_top_box (answer flag) | stg_answers             | Indicator that a single answer selected the maximum Likert option.                                                                                                         | $$ \text{answer\_is\_top\_box}(a) = \mathbf{1}\{\text{numeric\_value}(a)=\text{likert\_max\_for\_item}\} $$ |
| stg  | overall_top_box_pct (response)  | stg_responses           | Share of scored answers in a response that are top-box (maximum option).                                                                                                   | $$ \text{overall\_top\_box\_pct}(r) = \frac{1}{N_r}\sum_{a \in A_r}\mathbf{1}\{\text{answer\_is\_top\_box}(a)\} $$ |
| nreq | overall score trend over time                  | mart_prem_kpi_monthly    | The overall score is a normalized measure (0–100%) of how positively patients answer scored, ordinal PREM questions in a single response. When we look over time, we don’t just look at one response but compute daily (or monthly) averages across all responses in that period. This lets you monitor whether patient-reported experience is improving, declining, or staying stable. |  $$\text{overall\_score\_pct\_mean}(p) = \frac{1}{|\mathcal{R}_p|} \sum_{r \in \mathcal{R}_p} \text{overall\_score\_pct}(r) $$ |
| nreq | overall score per age band               | mart_prem_equity_slice      | Mean overall PREM score per month, stratified by age band (0–17, 18–34, …, 80+) and optionally gender.                                                             | $$ \text{overall\_score\_pct\_mean}(a) = \frac{1}{|\mathcal{R}_a|}\sum_{r \in \mathcal{R}_a} \text{overall\_score\_pct}(r) $$ |
| nreq | domains score (score vs top box)         | mart_prem_equity_slice      | Domain-level averages per month, stratified by age/gender. Both normalized mean scores and top-box percentages are tracked.                                         | $$ \text{domain\_score\_pct\_mean}(d) = \frac{1}{|\mathcal{R}_d|}\sum_{r \in \mathcal{R}_d} \text{domain\_score\_pct}(r) $$ |
| nreq | How do patients respond to each question?| mart_prem_item_heatmap      | Item-level summary: per questionnaire item, counts of responses in bottom, middle, and top categories; mean score and top-box rate.                                 | $$ \text{mean\_score\_pct}(i) = \tfrac{1}{N_i}\sum_{a \in A_i}\text{score\_pct}(a) \quad ; \quad \text{top\_box\_pct}(i) = \tfrac{1}{N_i}\sum \mathbf{1}\{a \text{ is top box}\} $$ |
| nreq | What problems matter most?               | mart_prem_item_heatmap      | Item-level *problem rate* (bottom-box proportion), i.e. how often patients select the most negative option for a question.                                          | $$ \text{problem\_rate\_pct}(i) = \tfrac{1}{N_i}\sum \mathbf{1}\{a \text{ is bottom box}\} $$ |
| nreq | Where are the problems?                  | mart_prem_item_heatmap      | Heatmap across domains/items for bottom-box and low scores, showing which areas have the highest problem concentration.                                             | Same as above, displayed by domain. |
| nreq | Who is way off the norm?                 | mart_prem_outliers          | Detects organizational units or clinicians whose mean PREM scores deviate significantly (z-score) from the network mean.                                            | $$ z = \frac{\bar{x}_{entity} - \mu_{network}}{\sigma_{network}} $$ (flag if \(|z|\) > 2) |
| nreq | Clinician Overall Score distribution     | mart_prem_outliers          | Distribution of average scores at the clinician level compared against network mean ±2σ bands.                                                                     | Same z-score formula, entity = clinician. |
| nreq | Organization Overall Score distribution  | mart_prem_outliers          | Distribution of average scores at the organization level compared against network mean ±2σ bands.                                                                  | Same z-score formula, entity = organization. |
| ppnq | nps                                      | mart_prem_nps               | Net Promoter Score: proportion of “promoters” minus “detractors” among NPS answers.                                                                                | $$ \text{NPS} = 100 \cdot \frac{n_{\text{promoters}} - n_{\text{detractors}}}{n_{\text{total}}} $$ |
| ppnq | sentiment distribution                   | mart_prem_text_sentiment    | Distribution of free-text comments across sentiment labels (positive, neutral, negative, unscored).                                                                | $$ P(\text{sentiment}=s) = \tfrac{1}{N}\sum \mathbf{1}\{\text{label}(c)=s\} $$ |
| ppnq | Theme × Sentiment                        | mart_prem_theme_sentiment_matrix | Cross-tabulation of themes (topics) with sentiment categories, per period/org, with rates within each theme.                                                    | $$ \text{pct\_within\_theme}(t,s) = \tfrac{n_{t,s}}{\sum_{s'}n_{t,s'}} $$ |
| ppnq | recent patient comments                  | mart_prem_text_sentiment    | Most recent free-text comments left by patients, with their NLP-derived sentiment and theme tags.                                                                  | No formula (direct text output + metadata). |




Disctinct PAtient : $$ \text{Patients} = \left| \{ r.\text{patient\_id} : r \in \mathcal{R} \} \right| $$

Has Free text : $$ \text{FreeTextRate} = \tfrac{1} {|\mathcal{R}|} \sum_{r \in \mathcal{R}} r.\text{has\_freetext\_int} = \tfrac{\#\{ r \in \mathcal{R} \mid r.\text{has\_freetext\_int}=1 \}}{|\mathcal{R}|} $$

Overall Score (nreq) :$$ \text{overall\_score\_pct\_mean}(d) = \frac{1}{|\mathcal{R}_d|}\sum_{r \in \mathcal{R}_d} \text{overall\_score\_pct}(r) $$

Overall top box pct : $$ \text{overall\_top\_box\_pct}(r) = \frac{1}{N_r}\sum_{a \in A_r}\mathbf{1}\{\text{answer\_is\_top\_box}(a)\} $$



### Responses per questionnaire
$$ \text{ResponsesByQuestionnaire}(q) = \sum_{r \in \mathcal{R}} \mathbf{1}\{ Q(r) = q \} $$

### Total responses
$$ \text{Responses} = \sum_{r \in \mathcal{R}} 1 $$

### Distinct patients
$$ \text{Patients} = \left| \{ r.\text{patient\_id} : r \in \mathcal{R} \} \right| $$

### Completeness
$$ \text{completion\_ratio\_total} = \tfrac{\#\text{answers to leaf items}}{\#\text{expected leaf items}} $$

### Has free text
$$ \text{FreeTextRate} = \tfrac{1} {|\mathcal{R}|} \sum_{r \in \mathcal{R}} r.\text{has\_freetext\_int} = \tfrac{\#\{ r \in \mathcal{R} \mid r.\text{has\_freetext\_int}=1 \}}{|\mathcal{R}|} $$

### Trends (responses over time)
$$ \text{Responses}(d,q) = \sum_{r \in \mathcal{R}} \mathbf{1}\{ r.\text{qr\_date}=d \wedge r.\text{questionnaire\_id}=q \} $$

### Response volume
$$ \text{responses\_n}(o,q) = \sum_{r \in \mathcal{R}_{o,q}} 1 $$

### Last seen answer
$$ \text{last\_seen\_answer}(o,q) = \max\{ a.\text{authored\_ts} : a \in A_{o,q} \} $$

### Days since last answer
$$ \text{days\_since\_last\_answer}(o,q) = \text{today} - \max\{ a.\text{authored\_ts} : a \in A_{o,q} \} $$

### Questionnaire last updated
$$ \text{last\_updated}(q) = \text{questionnaire\_last\_updated}(q) $$

### Questionnaire staleness per org
$$ \text{days\_since\_last\_update}(q) = \text{today} - \text{questionnaire\_last\_updated}(q) $$

### Overall Score (nreq)
$$ \text{overall\_score\_pct\_mean}(d) = \frac{1}{|\mathcal{R}_d|}\sum_{r \in \mathcal{R}_d} \text{overall\_score\_pct}(r) $$

### Top Box % (nreq)
$$ \text{overall\_top\_box\_pct\_mean}(d) = \frac{1}{|\mathcal{R}_d|}\sum_{r \in \mathcal{R}_d} \text{overall\_top\_box\_pct}(r) $$

### score_pct (answer level)
$$ \text{score\_pct}(a) = \frac{\text{numeric\_value}(a)}{\text{likert\_max\_for\_item}} $$

### overall_score (response level)
$$ \text{overall\_score\_pct}(r) = \frac{1}{N_r}\sum_{a \in A_r} \text{score\_pct}(a) $$

### answer_is_top_box (answer flag)
$$ \text{answer\_is\_top\_box}(a) = \mathbf{1}\{\text{numeric\_value}(a)=\text{likert\_max\_for\_item}\} $$

### overall_top_box_pct (response)
$$ \text{overall\_top\_box\_pct}(r) = \frac{1}{N_r}\sum_{a \in A_r}\mathbf{1}\{\text{answer\_is\_top\_box}(a)\} $$

### overall score trend over time
$$ \text{overall\_score\_pct\_mean}(p) = \frac{1}{|\mathcal{R}_p|} \sum_{r \in \mathcal{R}_p} \text{overall\_score\_pct}(r) $$

### overall score per age band
$$ \text{overall\_score\_pct\_mean}(a) = \frac{1}{|\mathcal{R}_a|}\sum_{r \in \mathcal{R}_a} \text{overall\_score\_pct}(r) $$

### domains score (score vs top box)
$$ \text{domain\_score\_pct\_mean}(d) = \frac{1}{|\mathcal{R}_d|}\sum_{r \in \mathcal{R}_d} \text{domain\_score\_pct}(r) $$

### How do patients respond to each question?
$$ \text{mean\_score\_pct}(i) = \tfrac{1}{N_i}\sum_{a \in A_i}\text{score\_pct}(a) \quad $$
$$ \quad \text{top\_box\_pct}(i) = \tfrac{1}{N_i}\sum \mathbf{1}\{a \text{ is top box}\} $$

### What problems matter most?
$$ \text{problem\_rate\_pct}(i) = \tfrac{1}{N_i}\sum \mathbf{1}\{a \text{ is bottom box}\} $$

### Who is way off the norm?
$$ z = \frac{\bar{x}_{entity} - \mu_{network}}{\sigma_{network}} $$

### NPS
$$ \text{NPS} = 100 \cdot \frac{n_{\text{promoters}} - n_{\text{detractors}}}{n_{\text{total}}} $$

### sentiment distribution
$$ P(\text{sentiment}=s) = \tfrac{1}{N}\sum \mathbf{1}\{\text{label}(c)=s\} $$

### Theme × Sentiment
$$ \text{pct\_within\_theme}(t,s) = \tfrac{n_{t,s}}{\sum_{s'}n_{t,s'}} $$
