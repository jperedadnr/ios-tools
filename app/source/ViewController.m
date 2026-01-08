#import "ViewController.h"

@interface ViewController ()

@end

@implementation ViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    UILabel *label = [[UILabel alloc] initWithFrame:CGRectMake(0, self.view.bounds.size.height / 2 - 15, self.view.bounds.size.width, 30)];
    label.text = @"Hello OpenJDK Mobile!";
    label.textAlignment = NSTextAlignmentCenter;

    [self.view addSubview:label];

}


@end
