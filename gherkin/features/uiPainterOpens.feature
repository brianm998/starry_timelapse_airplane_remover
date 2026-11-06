@uiPainterOpens @ui @mac-gui @desktop
Feature: The horizon painter opens on band selection, paints Sky, and Reset goes back to band selection

  H1 of the parity plan. The painter opens in band selection, where there is no Sky or Ground choice yet; once a band across the frame has
  been painted and the horizon found, the brush is Sky. Reset starts over from band selection, and the next horizon found has the brush on
  Sky again, whatever it was set to before.

  Scenario: Paint a band, switch to Ground, reset, and paint the band again
    Given a fresh copy of the sequence {sequence}
    When  I open the copied sequence without its startup questions
      And I choose the menu command "paintHorizon"
    Then  "painter.band" is shown
      And "painter.sky" is not shown
    When  I paint a band across "painter.canvas"
    Then  "painter.sky" is selected
      And "painter.ground" is not selected
    When  I click "painter.ground"
    Then  "painter.ground" is selected
      And "painter.sky" is not selected
    When  I click "painter.reset"
    Then  "painter.band" is shown
      And "painter.sky" is not shown
    When  I paint a band across "painter.canvas"
    Then  "painter.sky" is selected
      And "painter.ground" is not selected
