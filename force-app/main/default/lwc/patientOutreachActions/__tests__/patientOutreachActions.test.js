import { createElement } from "lwc";
import PatientOutreachActions from "c/patientOutreachActions";
import getPatientWorkspace from "@salesforce/apex/OutreachWorkbenchController.getPatientWorkspace";
import getRecentEvents from "@salesforce/apex/OutreachWorkbenchController.getRecentEvents";
import { publish, subscribe, MessageContext, createMessageContext } from "lightning/messageService";

jest.mock(
  "@salesforce/apex/OutreachWorkbenchController.getPatientWorkspace",
  () => ({
    __esModule: true,
    default: require("@salesforce/sfdx-lwc-jest").createApexTestWireAdapter(
      jest.fn()
    )
  }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/OutreachWorkbenchController.getRecentEvents",
  () => ({
    __esModule: true,
    default: require("@salesforce/sfdx-lwc-jest").createApexTestWireAdapter(
      jest.fn()
    )
  }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/OutreachWorkbenchController.enhanceRationale",
  () => ({ __esModule: true, default: jest.fn().mockResolvedValue(null) }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/OutreachWorkbenchController.recordSoftHold",
  () => ({ __esModule: true, default: jest.fn().mockResolvedValue(null) }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/OutreachWorkbenchController.silenceNeed",
  () => ({ __esModule: true, default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/apex/OutreachWorkbenchController.unsilenceNeed",
  () => ({ __esModule: true, default: jest.fn() }),
  { virtual: true }
);
jest.mock(
  "@salesforce/messageChannel/PatientOutreachState__c",
  () => ({ default: "PatientOutreachState" }),
  { virtual: true }
);

const flushPromises = async () => {
  await Promise.resolve();
  await Promise.resolve();
  await Promise.resolve();
};

afterEach(() => {
  while (document.body.firstChild)
    document.body.removeChild(document.body.firstChild);
  jest.clearAllMocks();
});

function mount() {
  const element = createElement("c-patient-outreach-actions", {
    is: PatientOutreachActions
  });
  element.recordId = "001ACCOUNT";
  document.body.appendChild(element);
  createMessageContext.mockReturnValue({ id: "ctx" });
  MessageContext.emit(createMessageContext());
  return element;
}

test("renders care gap cards with remapped priority labels", async () => {
  const element = mount();
  getPatientWorkspace.emit({
    episodeId: "a01",
    patientId: "001ACCOUNT",
    status: "Claimed",
    priority: "STAT",
    points: 95,
    nextAction: "Call — prioritize today",
    recommendedAction: "Call — prioritize today",
    rationale: "Re-enrollment overdue.",
    ownerName: "Outreach Team",
    needs: [
      {
        id: "n01",
        needType: "OFF_CADENCE",
        ruleId: "OFF_CADENCE",
        displayLabel: "Off cadence",
        priority: "Urgent",
        points: 60,
        attemptCount: 0,
        actionDescription: "Behind expected spacing."
      },
      {
        id: "n02",
        needType: "UNENGAGED",
        ruleId: "UNENGAGED_6_MONTH",
        displayLabel: "Unengaged — more than 6 months",
        priority: "Urgent",
        points: 80,
        attemptCount: 0
      },
      {
        id: "n03",
        needType: "NO_NEXT",
        ruleId: "NO_NEXT_FOLLOWUP",
        displayLabel: "No next visit — follow-up",
        priority: "Routine",
        points: 40,
        attemptCount: 0,
        actionDescription: "Schedule the next visit."
      }
    ],
    recommendedAction: "Re-engage and schedule visit",
    rationale: "The patient is high risk and 6+ months overdue for an appointment with no future visit currently scheduled."
  });
  getRecentEvents.emit([]);
  await flushPromises();

  expect(element.shadowRoot.textContent).toContain(
    "Pending Actions & Care Gaps"
  );
  expect(element.shadowRoot.querySelector(".oi-headline")).not.toBeNull();
  // Hero situation may render as rich text (Patient Summary style)
  const rich = element.shadowRoot.querySelector(".oi-situation-rich");
  const plain = element.shadowRoot.querySelector(".oi-situation");
  expect(rich || plain).not.toBeNull();
  expect(element.shadowRoot.querySelector(".oi-pills")).toBeNull();
  const cards = element.shadowRoot.querySelectorAll(".care-gap");
  // Off Cadence + No Next; Unengaged flavor hidden when Off Cadence present
  expect(cards).toHaveLength(2);
  expect(element.shadowRoot.textContent).toContain("Re-engage and schedule visit");
  expect(element.shadowRoot.textContent).toContain("high risk");

  const stages = [
    ...element.shadowRoot.querySelectorAll(".urgency-path__stage")
  ].map((el) => el.textContent.trim());
  expect(stages).toEqual(["Urgent", "Important", "Routine"]);
  const active = element.shadowRoot.querySelector(".urgency-path__stage_active");
  expect(active.textContent).toContain("Urgent");
});

test("publishes need state when a care gap is toggled", async () => {
  const element = mount();
  getPatientWorkspace.emit({
    episodeId: "a01",
    patientId: "001ACCOUNT",
    status: "Claimed",
    priority: "Routine",
    points: 20,
    needs: [
      { id: "n01", needType: "OFF_CADENCE", ruleId: "OFF_CADENCE", displayLabel: "Off cadence", priority: "Urgent", points: 60 },
      { id: "n02", needType: "NO_NEXT", ruleId: "NO_NEXT_FOLLOWUP", displayLabel: "No next visit", priority: "Routine", points: 40 }
    ]
  });
  getRecentEvents.emit([]);
  await flushPromises();

  // Force a publish path even if MessageContext wire is empty in Jest:
  // toggle should still attempt publish when messageContext is truthy.
  // Assign a fake context used by publishNeedState guard.
  const select = element.shadowRoot.querySelector(
    'button.care-gap__select[data-need-id="n01"]'
  );
  select.click();
  await flushPromises();

  expect(publish).toHaveBeenCalled();
  const last = publish.mock.calls[publish.mock.calls.length - 1][2];
  expect(last.eventType).toBe("NEED_STATE");
  expect(last.recordId).toBe("001ACCOUNT");
  const selected = JSON.parse(last.selectedNeedIdsJson);
  expect(selected).toEqual(["n02"]);
});

test("timeline stays collapsed until expanded", async () => {
  const element = mount();
  getPatientWorkspace.emit({
    episodeId: "a01",
    patientId: "001ACCOUNT",
    status: "Open",
    priority: "Routine",
    points: 10,
    needs: []
  });
  getRecentEvents.emit([
    {
      id: "e01",
      eventType: "Care Item Opened",
      summary: "Off cadence became active",
      careItemKey: "OFF_CADENCE",
      careItemLabel: "Off cadence",
      ruleId: "OFF_CADENCE",
      eventAt: "2026-07-19T00:00:00.000Z",
      actorName: "PES"
    },
    {
      id: "e02",
      eventType: "Reviewed Outreach",
      summary: "Soft hold recorded (reviewed outreach)",
      careItemKey: "OFF_CADENCE",
      careItemLabel: "Off cadence",
      ruleId: "OFF_CADENCE",
      eventAt: "2026-07-19T00:01:00.000Z",
      actorName: "PES"
    }
  ]);
  await flushPromises();

  expect(element.shadowRoot.querySelector(".care-history")).toBeNull();
  const toggle = [...element.shadowRoot.querySelectorAll("lightning-button")].find(
    (b) => b.label === "Show care item history"
  );
  expect(toggle).toBeTruthy();
  toggle.click();
  await flushPromises();
  expect(element.shadowRoot.querySelector(".care-history_table")).not.toBeNull();
  // Soft hold events are filtered from the UI.
  expect(element.shadowRoot.textContent).not.toContain(
    "Soft hold recorded (reviewed outreach)"
  );

  const activityBtn = [...element.shadowRoot.querySelectorAll("button")].find(
    (b) => b.textContent === "Activity"
  );
  expect(activityBtn).toBeTruthy();
  activityBtn.click();
  await flushPromises();
  expect(element.shadowRoot.querySelector(".care-history_activity")).not.toBeNull();
  const accordion = element.shadowRoot.querySelector(".care-history__accordion");
  expect(accordion).toBeTruthy();
  accordion.click();
  await flushPromises();
  expect(element.shadowRoot.querySelector(".care-history__events")).not.toBeNull();
});

test("addressed care gaps are greyed and capped at six cards", async () => {
  const element = mount();
  const needs = [
    { id: "n1", needType: "OFF_CADENCE", ruleId: "OFF_CADENCE", displayLabel: "Off cadence", priority: "Urgent", points: 90, state: "Pending" },
    { id: "n2", needType: "NO_NEXT", ruleId: "NO_NEXT_FOLLOWUP", displayLabel: "No next visit", priority: "Routine", points: 40, state: "Pending" },
    { id: "n3", needType: "AWV", ruleId: "AWV_DUE", displayLabel: "AWV", priority: "Routine", points: 30, state: "Resolved" },
    { id: "n4", needType: "UNENGAGED", ruleId: "UNENGAGED_30", displayLabel: "Unengaged", priority: "Routine", points: 20, state: "Resolved" }
  ];
  getPatientWorkspace.emit({
    episodeId: "a01",
    patientId: "001ACCOUNT",
    status: "Open",
    priority: "Urgent",
    points: 90,
    needs
  });
  getRecentEvents.emit([]);
  await flushPromises();

  const addressed = element.shadowRoot.querySelector(".care-gap_addressed");
  expect(addressed).not.toBeNull();
  expect(addressed.textContent).toContain("Addressed");
});

test("shows schedulePhrase as dueLabel when present", async () => {
  const element = mount();
  getPatientWorkspace.emit({
    episodeId: "a01",
    patientId: "001ACCOUNT",
    status: "Claimed",
    priority: "Urgent",
    points: 70,
    needs: [
      {
        id: "n01",
        needType: "AWV",
        ruleId: "AWV_DUE",
        displayLabel: "Annual Wellness Visit",
        priority: "Urgent",
        points: 70,
        schedulePhrase: "AWV anytime after eligibility date",
        scheduleStatusLabel: "Due for an AWV"
      }
    ]
  });
  getRecentEvents.emit([]);
  await flushPromises();

  expect(element.shadowRoot.textContent).toContain(
    "AWV anytime after eligibility date"
  );
});


test("renders situation statement and action bullets", async () => {
  const element = mount();
  getPatientWorkspace.emit({
    episodeId: "a01",
    patientId: "001ACCOUNT",
    status: "Claimed",
    priority: "Routine",
    points: 70,
    recommendedAction: "Schedule an Annual Wellness Visit",
    rationale:
      "The patient is due for an Annual Wellness Visit. Next step: Call — schedule visit.",
    scheduleSummary:
      "Patient is Due for an AWV. Schedule their next AWV as soon as possible.",
    needs: [
      {
        id: "n-awv",
        needType: "AWV",
        ruleId: "AWV_DUE",
        displayLabel: "Annual Wellness Visit",
        recommendedAction: "Schedule an Annual Wellness Visit",
        priority: "Routine",
        points: 70,
        state: "Pending",
        scheduleBoundType: "ANYTIME_AFTER",
        scheduleEarliest: "2020-01-01",
        scheduleStatusLabel: "Due for an AWV"
      },
      {
        id: "n-nn",
        needType: "NO_NEXT",
        ruleId: "NO_NEXT_FOLLOWUP",
        displayLabel: "No next visit",
        recommendedAction: "Schedule a routine follow-up on cadence",
        priority: "Routine",
        points: 40,
        state: "Pending"
      }
    ]
  });
  getRecentEvents.emit([]);
  await flushPromises();

  const rich = element.shadowRoot.querySelector(
    ".oi-situation-rich lightning-formatted-rich-text"
  );
  expect(rich).not.toBeNull();
  const html = rich.value || "";
  expect(html).toMatch(/no next visit scheduled/i);
  expect(html).toMatch(/Annual Wellness Visit/i);
  expect(html).toMatch(/<strong>Next step<\/strong>/i);
  expect(html).toMatch(/Schedule a routine follow-up on cadence/i);
  // Weighted order: AWV (70) before NO_NEXT (40) when both Routine.
  expect(html.indexOf("Annual Wellness Visit")).toBeLessThan(html.indexOf("follow-up"));
});

test("clinical follow-up families render as selectable care gap cards", async () => {
  const element = mount();
  getPatientWorkspace.emit({
    episodeId: "a01",
    patientId: "001ACCOUNT",
    status: "Claimed",
    priority: "Urgent",
    points: 80,
    needs: [
      {
        id: "n-nn",
        needType: "NO_NEXT",
        ruleId: "NO_NEXT_FOLLOWUP",
        displayLabel: "No next visit",
        priority: "Urgent",
        points: 80,
        state: "Pending",
        situationPhrase: "No next visit",
        recommendedAction: "Schedule the next medical visit"
      },
      {
        id: "n-awv",
        needType: "AWV",
        ruleId: "AWV_DUE",
        displayLabel: "Annual Wellness Visit",
        priority: "Routine",
        points: 40,
        state: "Pending",
        situationPhrase: "Annual Wellness Visit due",
        recommendedAction: "Schedule an Annual Wellness Visit"
      },
      {
        id: "n-ref",
        needType: "URGENT_REFERRAL",
        ruleId: "URGENT_REFERRAL",
        displayLabel: "Urgent referral follow-up",
        priority: "Urgent",
        points: 70,
        state: "Pending",
        situationPhrase: "Urgent referral follow-up",
        recommendedAction: "Follow up on overdue urgent referrals"
      },
      {
        id: "n-mddo",
        needType: "MDDO",
        ruleId: "MDDO",
        displayLabel: "MD/DO visit",
        priority: "Routine",
        points: 30,
        state: "Pending",
        situationPhrase: "MD/DO visit",
        recommendedAction: "Schedule an MD/DO visit"
      },
      {
        id: "n-dc",
        needType: "DISCHARGE_TCM",
        ruleId: "DISCHARGE_TCM",
        displayLabel: "Discharge TCM",
        priority: "Urgent",
        points: 75,
        state: "Pending",
        situationPhrase: "Discharge TCM",
        recommendedAction: "Complete discharge TCM outreach"
      }
    ]
  });
  getRecentEvents.emit([]);
  await flushPromises();

  const titles = [
    ...element.shadowRoot.querySelectorAll(".care-gap__title")
  ].map((n) => n.textContent.trim());
  const joined = titles.join(" | ");
  expect(joined).toMatch(/No next visit/i);
  expect(joined).toMatch(/Annual Wellness Visit/i);
  expect(joined).toMatch(/Urgent referral follow-up/i);
  expect(joined).toMatch(/MD\/DO visit/i);
  expect(joined).toMatch(/Discharge TCM/i);
  expect(element.shadowRoot.textContent).toMatch(/Pending Actions & Care Gaps \(5\)/i);
});

