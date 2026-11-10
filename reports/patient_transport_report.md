# Patient feedback report: Patient Transport (example)

*Example output of the aggregation test (step A6). 500 patient transport comments from the NHS public data. Tags:
Gemini 3.1 Pro + structured v3 prompt (C09). **Numbers** from the semantic view `REPORT_SV` (exact SQL counts; a
comment counts once per theme). **Text** written by Gemini 3.1 Pro with the map-reduce method (`REPORT_SUMMARIES`,
run 1); the text contains no numbers by design. A comment can raise several themes, so the theme counts add up to more
than 500.*

## Overview

Patients praise the transport service for its friendly, caring staff and clean vehicles, noting that drivers help
them feel safe and at ease. However, the biggest problems include extended waits for return journeys, difficulties
contacting the booking office by telephone, and a lack of communication regarding delays. Furthermore, patients
experience significant distress because their carers or family members are not permitted to accompany them to
appointments.

| Theme | Comments | % of all 500 | % negative | % positive | Top sub-themes (comments) |
|---|---|---|---|---|---|
| General | 252 | 50% | 3% | 85% | Positive experience & gratitude 203, Labelling not possible 18, Not assigned 15 |
| Staff | 168 | 34% | 6% | 93% | Staff manner & personal attributes 161, Staffing levels & responsiveness 6, Competence & training 3 |
| Service location, travel & transport | 107 | 21% | 41% | 47% | Transport to/ from services 106, Service location 2 |
| Access to medical care & support | 82 | 16% | 46% | 50% | Timeliness of care 43, Appointment arrangements 30, Contacting services 10 |
| Communication & involvement | 20 | 4% | 65% | 40% | Being kept informed 7, Interaction with family/ carers 4, Information directly from staff 4 |
| Environment, equipment & catering | 18 | 4% | 22% | 78% | Cleanliness & infection control 10, Environment, facilities & equipment 8, Sensory experience 1 |
| Patient journey & service coordination | 7 | 1% | 86% | 14% | Continuity of care 5, Discharge 2 |
| Medication & pain | 3 | 1% | 67% | 33% | Pain management 3 |

## Staff (168 comments, 6% negative)

Many patients praise the transport staff for being exceptionally friendly, helpful, and polite during their journeys.
Drivers and ambulance crews are frequently commended for their caring and chatty nature, which helps put patients at
ease. Staff also receive positive feedback for their professionalism and for providing physical assistance, such as
helping patients with wheelchairs or navigating stairs. However, a few patients report issues with unhelpful call
handlers and difficulties getting through to the booking office. Some negative comments also highlight isolated
incidents of abrupt behaviour, a lack of deaf awareness, and poor experiences with third-party taxi drivers who were
disrespectful.

> "Yes, I have to say your Patient Transport Crews are Very kind, very helpful, very caring and very nice people"
> "Sometimes it's difficult to get through/the call handler is very hard to talk to."
> "Not happy with Taxi driver who's booked by patient transport. Driver not very helpful and made me feel uncomfortable when I got to hospital."

## Service location, travel & transport (107 comments, 41% negative)

Many patients praise the transport service for arriving on time and highlight the friendly, helpful, and polite
nature of the drivers. However, the most frequently reported problem is the long waiting time to be picked up for the
return journey home after an appointment. Some patients also complain about uncomfortable, noisy vehicles with poor
suspension, and a few mention unhelpful private taxi drivers who do not assist with mobility needs. Despite these
issues, many disabled patients express deep gratitude for the service, noting they would be unable to attend hospital
without it.

> "The transport was on time it was clean and comfortable. The drivers were pleasant and helpful."
> "My last appointment I was kept waiting over 2 hours for transport home."
> "Not happy with Taxi driver who's booked by patient transport. Driver not very helpful and made me feel uncomfortable when I got to hospital."

*Judge note: "many disabled patients" is overstated - two or three comments say this.*

## Access to medical care & support (82 comments, 46% negative)

Many patients praise the service for being prompt and punctual, ensuring they arrive at their medical appointments on
time. However, some users report experiencing long wait times for their transport to arrive, both for initial pickups
and return journeys. A further frequent problem is the difficulty in contacting the service by telephone to book
transport, with patients facing extended periods on hold. A few comments also mention arriving late for appointments
and suggest providing better information or time schedules to help manage delays.

> "They were punctual, helpful, thoroughly nice people."
> "When you ring for transport they rarely pick the phone up, I've waited all day to book transport."
> "It was a long time to wait for the return ambulance."

## Communication & involvement (20 comments, 65% negative)

Many patients report significant distress and frustration because their carers or family members are not allowed to
accompany them, which is especially problematic for those with memory, hearing, or mobility issues. A frequent issue
is the lack of communication regarding expected arrival times and delays, leaving patients waiting without updates.
Some patients also mention poor communication regarding the type of transport provided and a need for information to
be explained more clearly to older individuals. Conversely, patients offer high praise for the friendly and polite
staff who engage them in conversation during journeys. Staff are also commended for explaining procedures clearly and
using preferred names.

> "Patient needs an escort as cannot hear, understand or remember health provider comments."
> "Provide better information especially if there is a longer wait than expected."
> "The staff are all friendly, caring, and considerate, use the name by which you liked to be called not formal surname unless asked for."

## Environment, equipment & catering (18 comments, 22% negative)

Many patients praise the cleanliness and comfort of the vehicles used for transport. Several people highlight the
helpful use of equipment, noting that staff frequently offer wheelchairs and use tail lifts to assist with mobility.
However, some patients report issues with vehicle accessibility and comfort, such as seats being too low or lacking
armrests, and experiencing harsh, noisy rides. A few patients also mention a lack of appropriate supplies, such as
proper travel sickness bags or protective masks and screens.

> "The transport was on time it was clean and comfortable."
> "Everything was fine. He made sure I had a wheelchair as I'm unsteady."
> "The vehicle had a harsh ride and was [unreadable] and therefore very noisy."

## Patient journey & service coordination (7 comments, 86% negative)

Patients highlight some issues with transport and care coordination, particularly regarding difficult journeys
involving taxis and long waits. Some patients report feeling unsupported when returning home, noting that transport
sometimes drops them off in the dark and cold without social services links. A few patients mention poor
communication of their specific needs to staff and transport drivers, such as requiring a wheelchair or an escort for
appointments. However, there is also praise for the assistance provided when transitioning from the hospital to home.

> "Transport sometimes return patients home in dark and cold."
> "Very good assist from the hospital to home."
> "It would be good if this could be noted on her records - instead I have to really press for permission every single time."

## Medication & pain (3 comments)

Some patients report experiencing severe pain and feeling that they needed help more quickly. Conversely, other
feedback highlights that the service successfully helped to ease their pain. Overall, while pain relief is effective
for some, the speed of providing this relief is a concern for others.

> "I was in agony and needed help quicker."
> "they helped ease my pain."

## General (252 comments, 3% negative)

Many patients express high satisfaction with the overall service, frequently describing their experiences as
excellent and well-organised. The staff receive significant praise for being friendly, caring, and helpful, which
makes patients feel safe and at ease during their journeys. Punctuality and the cleanliness of the vehicles are also
highlighted as positive aspects of the transport provided. A few patients raise concerns, mentioning issues such as
uncomfortable rides, the need for better preparation, and a desire for patient details to be saved on the system.
There is also a specific worry regarding the safeguarding of elderly patients and the need to vet volunteer drivers.

> "I have used this service a few times. Always friendly helpful drivers, cars are spotless. An excellent service."
> "Very thankful I've always found then able to make me feel safe."
> "Perhaps saving patients details on system allowing for easier service."
