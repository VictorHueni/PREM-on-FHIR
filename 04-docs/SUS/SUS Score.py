import pandas as pd

# Recreate the SUS dataset from the user text
data = [
    [1,1,"I think that I would like to use this system frequently","Neutral"],
    [1,2,"I found the system unnecessarily complex","Disagree"],
    [1,3,"I thought the system was easy to use","Agree"],
    [1,4,"I think that I would need the support of a technical person to be able to use this system","Disagree"],
    [1,5,"I found the various functions in this system were well integrated","Neutral"],
    [1,6,"I thought there was too much inconsistency in this system","Disagree"],
    [1,7,"I would imagine that most people would learn to use this system very quickly","Agree"],
    [1,8,"I found the system very cumbersome to use","Disagree"],
    [1,9,"I felt very confident using the system","Neutral"],
    [1,10,"I needed to learn a lot of things before I could get going with this system","Disagree"],
    [2,1,"I think that I would like to use this system frequently","Strongly agree"],
    [2,2,"I found the system unnecessarily complex","Strongly disagree"],
    [2,3,"I thought the system was easy to use","Strongly agree"],
    [2,4,"I think that I would need the support of a technical person to be able to use this system","Strongly disagree"],
    [2,5,"I found the various functions in this system were well integrated","Strongly agree"],
    [2,6,"I thought there was too much inconsistency in this system","Strongly disagree"],
    [2,7,"I would imagine that most people would learn to use this system very quickly","Strongly agree"],
    [2,8,"I found the system very cumbersome to use","Strongly disagree"],
    [2,9,"I felt very confident using the system","Agree"],
    [2,10,"I needed to learn a lot of things before I could get going with this system","Strongly disagree"],
]

df = pd.DataFrame(data, columns=["respondent","question_id","question_text","response"])

# Map Likert responses to SUS numeric scale (1-5)
mapping = {
    "Strongly disagree": 1,
    "Disagree": 2,
    "Neutral": 3,
    "Agree": 4,
    "Strongly agree": 5
}
df["response_num"] = df["response"].map(mapping)

# SUS calculation
def calculate_sus(responses):
    scores = []
    for q, resp in enumerate(responses, start=1):
        if q % 2 == 1:  # Odd-numbered question
            scores.append(resp - 1)
        else:  # Even-numbered question
            scores.append(5 - resp)
    return sum(scores) * 2.5

# Calculate SUS per respondent
sus_scores = df.groupby("respondent")["response_num"].apply(list).apply(calculate_sus).reset_index(name="SUS Score")

# Average SUS
average_sus = sus_scores["SUS Score"].mean()

sus_scores, average_sus
