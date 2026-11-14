# 0189: startup answers are pictures over their existing words

The three first questions use one `PictureChoice` button per answer in each client, fed by a small table
(id, art slot, label key) that the tests share. The word under the picture is the existing `ui.no/yes/static/moving`
string, so no keys are added. The id lives on the clickable element, not the picture, because UI features click by id.
