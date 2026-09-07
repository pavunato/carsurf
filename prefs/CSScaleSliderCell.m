#import "CSScaleSliderCell.h"
#import "CSConfig.h"
#import <CoreText/SFNTLayoutTypes.h>

/// The same font, with digits that do not change width as the value changes.
///
/// Building the monospaced font separately (monospacedDigitSystemFontOfSize:)
/// gives it its own metrics, and the value then sits slightly off the title
/// beside it — different ascender, different baseline once Dynamic Type scales
/// them apart. Deriving it from the title's own font keeps every metric
/// identical, so a baseline constraint lines them up exactly.
static UIFont *CSMonospacedDigits(UIFont *font) {
    if (!font) return nil;
    UIFontDescriptor *descriptor =
        [font.fontDescriptor fontDescriptorByAddingAttributes:@{
            UIFontDescriptorFeatureSettingsAttribute : @[ @{
                UIFontFeatureTypeIdentifierKey : @(kNumberSpacingType),
                UIFontFeatureSelectorIdentifierKey : @(kMonospacedNumbersSelector),
            } ],
        }];
    return [UIFont fontWithDescriptor:descriptor size:0.0] ?: font;
}

@implementation CSScaleSliderCell {
    UILabel *_carsurfLabel;
    UILabel *_carsurfValue;
    UISlider *_carsurfSlider;
}

- (instancetype)initWithStyle:(UITableViewCellStyle)style
              reuseIdentifier:(NSString *)reuseIdentifier
                    specifier:(PSSpecifier *)specifier {
    self = [super initWithStyle:style
                reuseIdentifier:reuseIdentifier
                      specifier:specifier];
    if (!self) return nil;

    self.selectionStyle = UITableViewCellSelectionStyleNone;
    self.titleLabel.hidden = YES;

    _carsurfLabel = [[UILabel alloc] initWithFrame:CGRectZero];
    _carsurfLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _carsurfLabel.font = [UIFont preferredFontForTextStyle:UIFontTextStyleBody];
    _carsurfLabel.adjustsFontForContentSizeCategory = YES;
    _carsurfLabel.text = specifier.name ?: @"Scale";
    [self.contentView addSubview:_carsurfLabel];

    // Monospaced digits: the value changes continuously while dragging, and
    // proportional digits make the whole label jitter as it does.
    _carsurfValue = [[UILabel alloc] initWithFrame:CGRectZero];
    _carsurfValue.translatesAutoresizingMaskIntoConstraints = NO;
    _carsurfValue.font = CSMonospacedDigits(_carsurfLabel.font);
    _carsurfValue.adjustsFontForContentSizeCategory = YES;
    _carsurfValue.textColor = UIColor.secondaryLabelColor;
    _carsurfValue.textAlignment = NSTextAlignmentRight;
    [_carsurfValue setContentCompressionResistancePriority:UILayoutPriorityRequired
                                                   forAxis:UILayoutConstraintAxisHorizontal];
    [_carsurfValue setContentHuggingPriority:UILayoutPriorityRequired
                                     forAxis:UILayoutConstraintAxisHorizontal];
    [self.contentView addSubview:_carsurfValue];

    _carsurfSlider = [[UISlider alloc] initWithFrame:CGRectZero];
    _carsurfSlider.translatesAutoresizingMaskIntoConstraints = NO;
    _carsurfSlider.minimumValue = [[specifier propertyForKey:@"min"] floatValue] ?: kCSMinScale;
    _carsurfSlider.maximumValue = [[specifier propertyForKey:@"max"] floatValue] ?: 2.0;
    _carsurfSlider.continuous = YES;
    _carsurfSlider.accessibilityLabel = specifier.name ?: @"Scale";
    [_carsurfSlider addTarget:self
                       action:@selector(carsurfSliderChanged:)
             forControlEvents:UIControlEventValueChanged];
    [self.contentView addSubview:_carsurfSlider];

    UILayoutGuide *margins = self.contentView.layoutMarginsGuide;
    [NSLayoutConstraint activateConstraints:@[
        [_carsurfLabel.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [_carsurfLabel.topAnchor constraintEqualToAnchor:self.contentView.topAnchor constant:9.0],
        [_carsurfValue.leadingAnchor constraintGreaterThanOrEqualToAnchor:_carsurfLabel.trailingAnchor
                                                                constant:8.0],
        [_carsurfValue.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [_carsurfValue.firstBaselineAnchor constraintEqualToAnchor:_carsurfLabel.firstBaselineAnchor],
        [_carsurfSlider.leadingAnchor constraintEqualToAnchor:margins.leadingAnchor],
        [_carsurfSlider.trailingAnchor constraintEqualToAnchor:margins.trailingAnchor],
        [_carsurfSlider.topAnchor constraintEqualToAnchor:_carsurfLabel.bottomAnchor constant:7.0],
        [_carsurfSlider.bottomAnchor constraintEqualToAnchor:self.contentView.bottomAnchor
                                                   constant:-9.0],
    ]];

    [self carsurfRefreshValueFromSpecifier:specifier];
    return self;
}

- (void)refreshCellContentsWithSpecifier:(PSSpecifier *)specifier {
    [super refreshCellContentsWithSpecifier:specifier];
    self.titleLabel.hidden = YES;
    _carsurfLabel.text = specifier.name ?: @"Scale";
    [self carsurfMatchValueFont];
    [self carsurfRefreshValueFromSpecifier:specifier];
}

- (void)traitCollectionDidChange:(UITraitCollection *)previous {
    [super traitCollectionDidChange:previous];
    if (previous.preferredContentSizeCategory != self.traitCollection.preferredContentSizeCategory) {
        [self carsurfMatchValueFont];
    }
}

/// The title tracks Dynamic Type on its own; the derived value font has to be
/// rebuilt from it, or the two drift apart at larger text sizes.
- (void)carsurfMatchValueFont {
    _carsurfValue.font = CSMonospacedDigits(_carsurfLabel.font);
}

- (void)carsurfRefreshValueFromSpecifier:(PSSpecifier *)specifier {
    if (!specifier || !_carsurfSlider) return;

    id stored = [specifier performGetter];
    CGFloat value = stored ? [stored doubleValue] : 1.0;
    if (!isfinite(value) || value <= 0.0) value = 1.0;
    value = MIN(MAX(value, _carsurfSlider.minimumValue), _carsurfSlider.maximumValue);

    _carsurfSlider.value = value;
    [self carsurfShowValue:value];
}

- (void)carsurfShowValue:(CGFloat)value {
    _carsurfValue.text = [NSString stringWithFormat:@"%.2f×", value];
}

- (void)carsurfSliderChanged:(UISlider *)slider {
    [self carsurfShowValue:slider.value];
    [self.specifier performSetterWithValue:@(slider.value)];
}

@end
