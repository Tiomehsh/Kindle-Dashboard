local FrontLightWidget = require("ui/widget/frontlightwidget")
local Size = require("ui/size")

local DashboardFrontLightWidget = FrontLightWidget:extend{}

function DashboardFrontLightWidget:layout()
    -- Native init resets these dimensions before dispatching to this layout.
    self.width = math.floor(math.min(self.screen_width, self.screen_height) * 0.85)
    self.inner_width = self.width - 2 * Size.padding.large
    self.button_width = math.floor(self.inner_width / 4)
    return FrontLightWidget.layout(self)
end

return DashboardFrontLightWidget
